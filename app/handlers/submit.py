"""Submit handler: the write half of the front door.

Accepts a request to analyse a player's archive, records it as PENDING, queues
it, and returns 202 with a URL to poll. It stays thin by design: analysis takes
30-90s per game and API Gateway hard-caps every request at 29s, so "accepted,
poll this" is the only answer this function can ever give.

The unit of work is a player-month, not a game. That is what the product is
about - skill across many games - and it is also what Chess.com's API serves:
monthly archives, one request each. One game would barely justify a queue.
"""

import json
import os
import re
import time

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["QUEUE_URL"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)
sqs = boto3.client("sqs")

# Letters, digits, underscore, hyphen - the characters Chess.com allows.
# Enforced because the username becomes part of both a partition key and a URL
# path; anything outside this set would corrupt one or the other.
USERNAME_RE = re.compile(r"^[a-z0-9_-]{1,50}$")

# The two platforms the app knows about. Chess.com is the ingestion source;
# Lichess is here because a verified link is possible there (see CLAUDE.md).
PLATFORMS = ("chesscom", "lichess")

# yyyy-mm. Chess.com's archive endpoints are month-granular, so this is the
# smallest unit that maps onto one upstream request.
ARCHIVE_RE = re.compile(r"^\d{4}-(0[1-9]|1[0-2])$")


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


def handler(event, context):
    user_id = _caller_sub(event)
    if not user_id:
        # Unreachable through the gateway: no token means a 401 before this
        # function is invoked. It fires only if a route is misconfigured
        # without an authorizer, so fail closed.
        return _response(401, {"error": "unauthenticated"})

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "request body must be JSON"})

    platform = str(body.get("platform") or "chesscom").strip().lower()
    if platform not in PLATFORMS:
        return _response(400, {"error": f"platform must be one of {list(PLATFORMS)}"})

    # Lowercased on the way in: chess usernames are case-insensitive, and this
    # is half a partition key - Hikaru and hikaru must not become two players.
    username = str(body.get("username") or "").strip().lower()
    if not USERNAME_RE.match(username):
        return _response(
            400, {"error": "username is required: letters, digits, _ or - only"}
        )

    archive = str(body.get("archive") or "").strip()
    if not ARCHIVE_RE.match(archive):
        return _response(400, {"error": "archive is required, format yyyy-mm"})

    player_key = f"PLAYER#{platform}#{username}"
    archive_key = f"ARCHIVE#{archive}"
    # Public and shared, so the id needs no secret component - it is derived
    # entirely from what was asked for, which is what makes the same request
    # from two users land on the same item.
    analysis_id = f"{platform}/{username}/{archive}"
    now = int(time.time())

    # Analysis is shared: if this player-month already exists, do not queue it
    # again. attribute_not_exists on the partition key is the standard
    # conditional-insert idiom - it succeeds only when the item is absent, so
    # two concurrent submits cannot both enqueue.
    try:
        table.put_item(
            Item={
                "PK": player_key,
                "SK": archive_key,
                "platform": platform,
                "username": username,
                "archive": archive,
                "status": "PENDING",
                "requestedAt": now,
                # Who asked first. An attribution note, not an owner - anyone
                # may read this item.
                "requestedBy": user_id,
            },
            ConditionExpression="attribute_not_exists(PK)",
        )
    except table.meta.client.exceptions.ConditionalCheckFailedException:
        # Already analysed or already queued. This is the dedup the product
        # asks for: re-analysing a player someone else already ran is waste.
        existing = table.get_item(Key={"PK": player_key, "SK": archive_key}).get(
            "Item", {}
        )
        domain = event["requestContext"]["domainName"]
        return _response(
            200,
            {
                "id": analysis_id,
                "status": existing.get("status", "PENDING"),
                "statusUrl": f"https://{domain}/analysis/{analysis_id}",
                "deduplicated": True,
            },
        )

    # Item first, then message. If the send fails the client gets a 500 and a
    # PENDING item exists with no message - visible in the table and harmless.
    # The other order can queue work for an item the table never heard of.
    sqs.send_message(
        QueueUrl=QUEUE_URL,
        MessageBody=json.dumps(
            {"id": analysis_id, "platform": platform, "username": username,
             "archive": archive}
        ),
    )

    domain = event["requestContext"]["domainName"]
    return _response(
        202,
        {
            "id": analysis_id,
            "status": "PENDING",
            "statusUrl": f"https://{domain}/analysis/{analysis_id}",
        },
    )
