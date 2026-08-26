"""Submit handler: the write half of the front door.

Accepts a request to analyse a player, resolves every monthly archive that
player has, and queues one message per month. Returns 202 with a URL to poll.
It stays thin by design: API Gateway hard-caps every request at 29s, so
"accepted, poll this" is the only answer this function can ever give.

The unit of work is a player-month, but the unit of *request* is a player.
Asking a user which month to analyse would push a detail of Chess.com's API
into the product; the interesting question is a player's history, not one
month of it. So submit fans out - and the worker stays exactly as constrained
as before: one message, one HTTP request, one item.

The fan-out is uncapped. A long-lived account is ~150 months, and the first
pass is slow by design. That is affordable because it happens once: past
months are immutable, so every later submit skips them at the front door and
re-queues only the month still being played.
"""

import datetime
import json
import os
import re
import time
import urllib.error
import urllib.request

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["QUEUE_URL"]
USER_POOL_ID = os.environ["USER_POOL_ID"]

# Chess.com's API is free and unauthenticated, so this header is the only thing
# identifying us. They try to reach the contact address before blocking an IP.
USER_AGENT = os.environ.get(
    "CHESSCOM_USER_AGENT",
    "chess-cloud-project/0.1 (learning project; wenkang.hoo@gmail.com)",
)

API_ROOT = "https://api.chess.com/pub"

table = boto3.resource("dynamodb").Table(TABLE_NAME)
sqs = boto3.client("sqs")
cognito = boto3.client("cognito-idp")

# sub -> verified, for the life of this execution environment. A user does not
# become unverified, so a cached True stays true; a cached False is not stored
# at all, so someone who verifies mid-session is not locked out until the
# container recycles. Bounded because a container is short-lived and one entry
# is a string and a bool.
_verified_subs = set()

# Letters, digits, underscore, hyphen - the characters Chess.com allows.
# Enforced because the username becomes part of both a partition key and a URL
# path; anything outside this set would corrupt one or the other.
USERNAME_RE = re.compile(r"^[a-z0-9_-]{1,50}$")

# Chess.com is the only ingestion source. Lichess exists in this app for
# account linking (Phase 2) and has no equivalent archive-list endpoint, so
# accepting it here would produce a confusing upstream 404 rather than an
# answer. Rejected explicitly until Lichess ingestion is actually built.
INGESTABLE_PLATFORMS = ("chesscom",)

# The archive list returns full URLs ending in /yyyy/mm.
ARCHIVE_URL_RE = re.compile(r"/(\d{4})/(\d{2})$")


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _caller_sub(event):
    """The verified user id, straight from the token the gateway validated.

    API Gateway put this here only after checking the signature against the
    pool's JWKS, plus issuer, audience and expiry. Nothing the client sent can
    reach this field, which is what separates it from anything in the body.
    """
    claims = (
        event.get("requestContext", {}).get("authorizer", {}).get("jwt", {})
    ).get("claims", {})
    return claims.get("sub")


def email_verified(user_id):
    """Whether Cognito has confirmed this user owns their email address.

    Looked up rather than read from the token, and that is the whole reason
    this function exists. `email_verified` is an *id* token claim; the gateway
    authorizes the *access* token, which carries sub, scope, client_id and
    token_use and nothing about the email. Gating on a claim that never
    arrives would reject every caller.

    The alternatives were worse. Sending the id token instead would authorize
    with a token meant for the client, and putting the claim in the access
    token needs a pre-token-generation Lambda, which requires the ESSENTIALS
    tier - a per-MAU charge against a budget of about two dollars a month, to
    move one boolean. This is one call on a route that already spends seconds
    fanning out, so it is bought cheaply.

    Fails closed: an error looking the user up is treated as unverified.
    """
    if user_id in _verified_subs:
        return True

    try:
        user = cognito.admin_get_user(UserPoolId=USER_POOL_ID, Username=user_id)
    except cognito.exceptions.UserNotFoundException:
        return False
    except Exception:
        return False

    for attribute in user.get("UserAttributes", []):
        if attribute.get("Name") == "email_verified":
            if str(attribute.get("Value", "")).strip().lower() == "true":
                _verified_subs.add(user_id)
                return True
            return False
    return False


def list_archives(username):
    """Every yyyy-mm that player has games for, oldest first.

    Returns None if the player does not exist. That is the common 404 - a
    typo - and catching it here means no item is written and no message is
    queued for a player who was never real.
    """
    url = f"{API_ROOT}/player/{username}/games/archives"
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            body = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return None
        raise

    months = []
    for archive_url in body.get("archives", []):
        match = ARCHIVE_URL_RE.search(archive_url)
        if match:
            months.append(f"{match.group(1)}-{match.group(2)}")
    return months


def current_archive():
    """The yyyy-mm that is still being played, in UTC.

    UTC because that is what Chess.com keys its archives by. Using local time
    would name the wrong month for a few hours either side of midnight, and
    the symptom - a live month treated as history, so new games never picked
    up - would look like a caching bug rather than a clock one.
    """
    today = datetime.datetime.now(datetime.timezone.utc)
    return f"{today.year:04d}-{today.month:02d}"


def claim_month(player_key, archive, platform, username, user_id, now, live):
    """Insert the month as PENDING, unless it is already done or in flight.

    Returns True if this call claimed the work and should queue a message.

    attribute_not_exists is the standard conditional-insert idiom - it
    succeeds only when the item is absent, so two concurrent submits cannot
    both enqueue. Two deliberate exceptions:

    FAILED: a failure records what happened on the last attempt, not a
    permanent verdict on the player. Chess.com releases deleted usernames for
    re-registration, so a month that 404'd may later belong to a different,
    active player - and without this clause dedup would make that player's
    games permanently unreachable.

    The live month (`live=True`): a past month is immutable - 2019 will never
    gain a game, so skipping it forever is correct - but the current month is
    still being played. Without this, re-submitting a player picked up nothing
    new, because the one month that could have changed was the one dedup
    skipped. This is also what gives the worker's ETag something to do: the
    live month is re-queued every time, and `If-None-Match` is what makes that
    cost 0.15s and no bytes on the days the player did not play.
    """
    try:
        # UpdateItem, not PutItem. PutItem replaces the whole item, which on a
        # FAILED re-claim would wipe the stored `etag` - destroying exactly the
        # thing that makes the re-fetch cheap, and forcing a full 3.4MB
        # download of an archive that had not changed. Setting named attributes
        # leaves the ETag in place, so a re-queued month can still come back
        # 304. Proven the wrong way round in a drill: the PutItem version
        # re-fetched an unchanged month in full.
        table.update_item(
            Key={"PK": player_key, "SK": f"ARCHIVE#{archive}"},
            UpdateExpression=(
                "SET #s = :pending, platform = :platform, #u = :username,"
                " #a = :archive, requestedAt = :now,"
                # Who asked first. An attribution note, not an owner - anyone
                # may read this item. if_not_exists keeps the original
                # requester across a re-claim.
                " requestedBy = if_not_exists(requestedBy, :user)"
                # Drop the previous failure's reason: the month is being
                # retried, so a stale error would misreport a PENDING item.
                " REMOVE #e"
            ),
            # The live month may also be re-claimed from COMPLETE - but never
            # from PENDING, or a re-submit arriving while the queue is still
            # draining would enqueue the same month twice.
            ConditionExpression=(
                "attribute_not_exists(PK) OR #s = :failed OR #s = :complete"
                if live
                else "attribute_not_exists(PK) OR #s = :failed"
            ),
            # archive, status and username are all DynamoDB reserved words, so
            # they cannot appear literally in an UpdateExpression - unlike in a
            # PutItem, where they are just attribute names.
            ExpressionAttributeNames={
                "#s": "status",
                "#a": "archive",
                "#u": "username",
                "#e": "error",
            },
            ExpressionAttributeValues={
                ":pending": "PENDING",
                ":failed": "FAILED",
                ":platform": platform,
                ":username": username,
                ":archive": archive,
                ":now": now,
                ":user": user_id,
                **({":complete": "COMPLETE"} if live else {}),
            },
        )
        return True
    except table.meta.client.exceptions.ConditionalCheckFailedException:
        # Already COMPLETE, PENDING or RUNNING. This is the dedup the product
        # asks for: re-analysing a month someone else already ran is waste.
        return False


def queue_months(platform, username, months):
    """Send one message per month, ten at a time.

    Batched because a long-lived account is ~150 months and this runs inside a
    user-facing request. One message per month is what keeps the worker's
    contract intact: one message, one HTTP request, one item.
    """
    for start in range(0, len(months), 10):
        batch = months[start : start + 10]
        sqs.send_message_batch(
            QueueUrl=QUEUE_URL,
            Entries=[
                {
                    "Id": str(start + offset),
                    "MessageBody": json.dumps(
                        {
                            "id": f"{platform}/{username}/{archive}",
                            "platform": platform,
                            "username": username,
                            "archive": archive,
                        }
                    ),
                }
                for offset, archive in enumerate(batch)
            ],
        )


def handler(event, context):
    user_id = _caller_sub(event)
    if not user_id:
        # Unreachable through the gateway: no token means a 401 before this
        # function is invoked. It fires only if a route is misconfigured
        # without an authorizer, so fail closed.
        return _response(401, {"error": "unauthenticated"})

    # Submit is the one route that spends money - it fans a username out into
    # ~200 fetches. Reads stay open to everyone because the data is public
    # either way, so this gates who can start work, not who can see it.
    #
    # Largely defence in depth: an unconfirmed account cannot sign in at all,
    # so it cannot reach here. What this catches is the narrower case - an
    # address changed after signup, or an account confirmed by an admin path.
    if not email_verified(user_id):
        return _response(
            403,
            {
                "error": "verify your email address before submitting",
                "code": "email_unverified",
            },
        )

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "request body must be JSON"})

    platform = str(body.get("platform") or "chesscom").strip().lower()
    if platform not in INGESTABLE_PLATFORMS:
        return _response(
            400,
            {"error": f"platform must be one of {list(INGESTABLE_PLATFORMS)}"},
        )

    # Lowercased on the way in: chess usernames are case-insensitive, and this
    # is half a partition key - Hikaru and hikaru must not become two players.
    username = str(body.get("username") or "").strip().lower()
    if not USERNAME_RE.match(username):
        return _response(
            400, {"error": "username is required: letters, digits, _ or - only"}
        )

    try:
        months = list_archives(username)
    except (urllib.error.URLError, TimeoutError) as exc:
        # Upstream is unreachable or slow. Nothing has been written, so the
        # client can simply try again.
        return _response(503, {"error": f"could not reach chess.com: {exc}"})

    if months is None:
        return _response(404, {"error": f"no such player: {username}"})

    player_key = f"PLAYER#{platform}#{username}"
    now = int(time.time())

    # Claim first, then queue. A claimed month with no message is visible in
    # the table as PENDING and harmless; the other order can queue work for an
    # item the table never heard of.
    live = current_archive()
    queued = [
        archive
        for archive in months
        if claim_month(
            player_key, archive, platform, username, user_id, now, archive == live
        )
    ]
    queue_months(platform, username, queued)

    domain = event["requestContext"]["domainName"]
    return _response(
        202,
        {
            "player": f"{platform}/{username}",
            "archives": len(months),
            "queued": len(queued),
            # Already COMPLETE or in flight from an earlier submit. On a
            # re-submit of an unchanged player this is every month bar the live
            # one, and the request costs nothing beyond the archive-list lookup.
            "skipped": len(months) - len(queued),
            # Whether the still-being-played month was re-queued. False only if
            # it is already in flight from a submit that has not drained yet.
            "refreshed": live in queued,
            "statusUrl": f"https://{domain}/player/{platform}/{username}",
        },
    )
