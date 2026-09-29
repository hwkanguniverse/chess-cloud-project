"""Analyse handler: ask for a player's recent games to be evaluated.

The expensive half of the product, and deliberately a separate request from
`POST /games`. Fetching a profile is cheap, unbounded and useful on its own -
counts, W/D/L, ratings, time controls, all with no engine. Evaluation costs
real CPU, so it happens only when somebody asks for it rather than as a side
effect of ingesting. That also means the directory can fill with ingested
players without paying to evaluate any of them.

Authenticated, like submit, because it spends money. Not gated on a verified
chess account: the work is bounded per player (100 games per time control) and
already-evaluated games are skipped, so re-analysing a player costs nothing and
there is no unbounded spend for verification to prevent. Analysis is keyed by
player rather than by user, so a popular player is paid for once by whoever
asks first.

**One message per game, not per player.** This route resolves a player into the
games that need evaluating and fans out, exactly as submit resolves a player
into archives. That is what lets ten evaluators work on one player at once: a
per-player message pins the whole job to a single task however many are
running, which measured at ~170 minutes for 227 games with a second worker
idle beside it.

Selection lives here rather than in the worker because it is a question about
the table, and answering it once at the front door is cheaper than having
every worker re-derive it.
"""

import json
import logging
import os
import re
import time

import boto3
from boto3.dynamodb.conditions import Key
from botocore.exceptions import ClientError

TABLE_NAME = os.environ["TABLE_NAME"]
EVAL_QUEUE_URL = os.environ["EVAL_QUEUE_URL"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)
sqs = boto3.client("sqs")

# The runtime owns the handler and its JSON format (logging_config in
# Terraform); this only asks for the logger. requestId is added by the
# runtime, and the same ID rides in every message this call queues.
log = logging.getLogger()

PLATFORM_RE = re.compile(r"^(chesscom|lichess)$")
USERNAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,50}$")

# Per time control, newest first. Overall would be wrong: a player's last 100
# games can be entirely one control - theohwk's would be nearly all rapid,
# hiding 437 blitz games - so the cap is applied per control and the worst
# case is four controls of 100.
GAMES_PER_CLASS = int(os.environ.get("EVAL_GAMES_PER_CLASS", "100"))

# Which time controls are worth evaluating at all. Daily is excluded: a
# correspondence player moves with an engine and an opening database open, so
# centipawn loss there measures their *tools*, not their judgement. Averaging
# it in with real-time play makes the headline figure describe two different
# activities at once.
#
# Duplicated in player.py, which must exclude by the same rule or its derived
# counts would report daily-heavy months as permanently under-evaluated. Kept
# as a constant in both rather than a shared module because each handler is
# packaged as its own single-file zip - the same reason EVAL_DEPTH is
# duplicated against the evaluator.
EVAL_CLASSES = set(
    c.strip()
    for c in os.environ.get("EVAL_CLASSES", "bullet,blitz,rapid").split(",")
    if c.strip()
)

# The depth the evaluator runs at. Duplicated here only to decide what still
# needs work; the worker owns the actual setting.
DEPTH = int(os.environ.get("EVAL_DEPTH", "18"))


# --- Rate limiting ---------------------------------------------------------
#
# A token bucket per account: RATE_BURST tokens, refilling one per
# RATE_REFILL_SECONDS. It replaces the profile-token verification this phase
# cut, and it is the control Phase F was already owed - one mechanism serving
# both.
#
# **Charged per distinct new player, not per request.** Re-submitting an
# already-analysed player queues nothing and costs $0.00, and that is the
# property the whole no-verification argument rests on: if a free request
# still burned quota, the dedup would stop being free. So the bucket is
# debited only when selection actually found work.
#
# A bucket rather than a fixed hourly counter because the product is about
# comparing players: someone looking at themselves and two friends should not
# wait three hours. Bursting five and then converging to one per hour keeps
# first use normal while bounding sustained use to the same rate a flat 1/hour
# would.
#
# **This bounds an account, and accounts are free.** See the registration note
# in PHASE-E.md - the real backstop is the budget alarm, and closing the
# registration hole is future work rather than something this control claims
# to do.
RATE_BURST = int(os.environ.get("ANALYSE_RATE_BURST", "5"))
RATE_REFILL_SECONDS = int(os.environ.get("ANALYSE_RATE_REFILL_SECONDS", "3600"))


def take_token(user_id, now=None):
    """Debit one token, or report how long until the next one.

    Returns (allowed, retry_after_seconds).

    Refill is computed rather than scheduled: the item stores the time the
    bucket was last full-priced, and how many whole refill periods have
    elapsed since is arithmetic. That means no timer, no sweeper, and an
    account that has been idle for a day simply reads as full.

    The whole update is one conditional UpdateItem. Read-then-write would be a
    race two parallel requests win together - the exact bug a rate limit is
    supposed to prevent - so the condition carries the decision and a failed
    condition *is* the rejection.
    """
    now = int(time.time()) if now is None else now
    key = {"PK": f"USER#{user_id}", "SK": "RATE#analyse"}

    item = table.get_item(Key=key).get("Item")

    if not item:
        tokens, updated = RATE_BURST, now
    else:
        tokens = int(item.get("tokens", RATE_BURST))
        updated = int(item.get("updatedAt", now))
        earned = (now - updated) // RATE_REFILL_SECONDS
        if earned > 0:
            tokens = min(RATE_BURST, tokens + earned)
            # Advance by whole periods only, so the remainder still counts
            # towards the next token rather than being rounded away on every
            # call. Without this, frequent polling would refill nothing.
            updated += earned * RATE_REFILL_SECONDS

    if tokens <= 0:
        return False, max(1, (updated + RATE_REFILL_SECONDS) - now)

    try:
        table.update_item(
            Key=key,
            UpdateExpression=(
                "SET tokens = :t, updatedAt = :u, expiresAt = :x"
            ),
            # Guards the read above: if another request debited between the
            # GetItem and here, the stored count no longer matches what this
            # call decided from, and it loses rather than double-spending.
            ConditionExpression=(
                "attribute_not_exists(tokens) OR tokens = :expected"
            ),
            ExpressionAttributeValues={
                ":t": tokens - 1,
                ":u": updated,
                ":expected": int(item["tokens"]) if item else 0,
                # Swept by the same TTL the OAuth flow uses. A bucket that has
                # had time to refill completely is indistinguishable from no
                # bucket at all, so letting it be deleted costs nothing.
                ":x": now + (RATE_BURST + 1) * RATE_REFILL_SECONDS,
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        # Lost the race. One token's worth of pessimism is the right answer
        # here: the competing request got it.
        return False, RATE_REFILL_SECONDS

    return True, 0


# --- In-flight claims ------------------------------------------------------
#
# Selection's dedup asks each game whether it already has evals at this depth,
# and a game is only stamped once the engine has *finished* it. So for the
# whole length of a run - 14 minutes for theohwk's 201 games - every queued
# game still answers "not evaluated", and a second POST /analyse re-queues all
# of them.
#
# Measured, not theorised: a re-submit mid-run produced 402 messages for 201
# games and spent a second token. 166 duplicates were absorbed by the worker's
# guard for a GetItem each, but **17 games were evaluated twice** - the
# duplicate arriving while the original was mid-engine, so both GetItem checks
# saw an unevaluated game.
#
# One claim item per player rather than a marker on each of 201 games: that
# would turn a read-only front door into a bulk writer and need
# BatchWriteItem, an action this project has been caught missing twice.
#
# It expires rather than being cleared. A claim that can only be set is a trap
# - a crashed run would wedge the player forever - so the window ages out and
# the next request proceeds normally. Same reasoning as the ETag and the
# evalDepth guard.
CLAIM_SECONDS = int(os.environ.get("ANALYSE_CLAIM_SECONDS", "1200"))


def claim_player(pk, games, now=None):
    """Claim a player's evaluation run, or report the live claim's age.

    Returns (claimed, already_queued). `already_queued` is the game count the
    live claim recorded, so the caller can say what is already in flight
    rather than only refusing.

    The condition does the deciding, exactly as take_token does: a claim is
    written only when none is live, and losing that race is indistinguishable
    from finding a live claim - both mean somebody else is already running it.
    """
    now = int(time.time()) if now is None else now
    key = {"PK": pk, "SK": "ANALYSE#claim"}

    existing = table.get_item(Key=key).get("Item")
    if existing and int(existing.get("expiresAt", 0)) > now:
        return False, int(existing.get("games", 0))

    try:
        table.update_item(
            Key=key,
            UpdateExpression=(
                "SET queuedAt = :q, games = :g, expiresAt = :x"
            ),
            # Absent or expired, checked server-side. DynamoDB's TTL sweep is
            # asynchronous - up to ~48h late - so an expired claim may still be
            # present, and the condition has to treat "expired" as "absent"
            # itself rather than trusting the sweep to have run.
            ConditionExpression=(
                "attribute_not_exists(expiresAt) OR expiresAt <= :now"
            ),
            ExpressionAttributeValues={
                ":q": now,
                ":g": games,
                ":x": now + CLAIM_SECONDS,
                ":now": now,
            },
        )
    except ClientError as exc:
        if exc.response["Error"]["Code"] != "ConditionalCheckFailedException":
            raise
        # Another request claimed it between the read and the write. Same
        # answer as finding a live claim: it is already running.
        return False, games

    return True, 0


def release_claim(pk):
    """Drop a claim whose run never started.

    Only for the path where the claim was written and then the request failed
    before fanning out. A claim is otherwise left to expire: a *successful*
    run must keep it for the whole window, which is the entire point.
    """
    try:
        table.delete_item(Key={"PK": pk, "SK": "ANALYSE#claim"})
    except ClientError:
        # Best effort. The claim expires on its own, so a failed delete costs
        # the user a wait rather than correctness - not worth failing the
        # request that is already returning an error.
        pass


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _caller_sub(event):
    claims = (
        event.get("requestContext", {}).get("authorizer", {}).get("jwt", {})
    ).get("claims", {})
    return claims.get("sub")


def select_games(pk):
    """The last GAMES_PER_CLASS games per time control that still need evals.

    One Query per evaluable class on the by-class index, newest first, Limit
    GAMES_PER_CLASS - so a player with 65,000 blitz games reads 100 index
    entries for blitz, not 65,000 games. Must stay identical to player.py's
    newest_per_class, or progress would show work nothing will ever queue.

    This was a walk over the player's games until every class was full, and
    the walk is why this route once **timed out at 20 s** reading Hikaru's
    70,344 games to select 300. Stopping early fixed Hikaru but not a player
    who has ever played fewer than 100 games of one class: that class never
    fills, so the walk read their whole history every time. The index has no
    such case.

    Games already evaluated at this depth count towards the cap without being
    re-queued. That is what makes re-analysing nearly free, and it has to be
    per *game* rather than per player: a player analysed last month has 100
    evaluated games, but their newest 100 now includes games played since, so
    a per-player check would never pick those up. The same insight as the
    ETag, one layer down.

    Time controls outside EVAL_CLASSES are never queried, so excluding daily
    does not consume a slot that a blitz game could have used. They are
    counted from the month summaries rather than folded into `skipped`, which
    means something different: skipped games *are* evaluated, excluded games
    never will be.
    """
    per_class = {}
    todo = []
    skipped = 0
    for klass in sorted(EVAL_CLASSES):
        page = table.query(
            IndexName="by-class",
            KeyConditionExpression=Key("classKey").eq(f"{pk}#{klass}"),
            ScanIndexForward=False,  # SK leads with the month: newest first
            Limit=GAMES_PER_CLASS,
            # The index holds keys and evalDepth only. No pgn - the worker
            # reads that itself.
            ProjectionExpression="SK, evalDepth",
        )
        items = page.get("Items", [])
        if not items:
            continue
        per_class[klass] = len(items)
        for item in items:
            if item.get("evalDepth") == DEPTH:
                skipped += 1
            else:
                todo.append(item["SK"])

    # Out of scope by rule, not by cap. Counted separately so the response
    # can say "26 daily games, deliberately not evaluated" rather than
    # leaving them indistinguishable from games that simply have not been
    # reached yet. From the month summaries, which already count games per
    # class - exact over the whole history, and a few small items to read.
    excluded = {}
    kwargs = {
        "KeyConditionExpression": Key("PK").eq(pk) & Key("SK").begins_with("ARCHIVE#"),
        "ProjectionExpression": "summary",
    }
    while True:
        page = table.query(**kwargs)
        for month in page.get("Items", []):
            by_class = (month.get("summary") or {}).get("byClass") or {}
            for klass, n in by_class.items():
                if klass not in EVAL_CLASSES:
                    excluded[klass] = excluded.get(klass, 0) + int(n)
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    seen_any = bool(per_class) or bool(excluded)
    return todo, skipped, per_class, excluded, seen_any


def fan_out(pk, sks, user_id, request_id):
    """One message per game, ten at a time.

    SendMessageBatch is a distinct IAM action from SendMessage rather than a
    variant of it - granting only the latter fails every fan-out with
    AccessDenied, which this project has already been caught by once.

    request_id is this invocation's, so every game's evaluator lines - and any
    message that ends up in the DLQ - trace back to the analyse that queued it.
    """
    sent = 0
    for start in range(0, len(sks), 10):
        chunk = sks[start : start + 10]
        sqs.send_message_batch(
            QueueUrl=EVAL_QUEUE_URL,
            Entries=[
                {
                    "Id": str(start + offset),
                    "MessageBody": json.dumps(
                        {
                            "pk": pk,
                            "sk": sk,
                            "requestedBy": user_id,
                            "requestId": request_id,
                        }
                    ),
                }
                for offset, sk in enumerate(chunk)
            ],
        )
        sent += len(chunk)
    return sent


def handler(event, context):
    user_id = _caller_sub(event)
    if not user_id:
        return _response(401, {"error": "unauthenticated"})

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "request body must be JSON"})

    platform = str(body.get("platform") or "chesscom").strip().lower()
    if not PLATFORM_RE.match(platform):
        return _response(400, {"error": "unknown platform"})

    username = str(body.get("username") or "").strip().lower()
    if not USERNAME_RE.match(username):
        return _response(400, {"error": "malformed username"})

    pk = f"PLAYER#{platform}#{username}"
    todo, skipped, per_class, excluded, seen_any = select_games(pk)

    # The player must already be ingested. Evaluation reads stored PGNs, so
    # asking to analyse a player nobody has fetched is a request for work that
    # cannot be done - better a 404 here than messages that fail in the worker
    # and reach the DLQ looking like a real fault.
    if not seen_any:
        return _response(
            404,
            {
                "error": "no games stored for this player",
                "hint": f"POST /games with {username} first",
            },
        )

    # Claimed before the token is charged, so a request that is refused for
    # duplicating a live run costs nothing. The other order would take a token
    # and then decline to do any work with it.
    if todo:
        claimed, already_queued = claim_player(pk, len(todo))
        if not claimed:
            # Not an error: the work the caller asked for is already happening.
            # 202 with queued 0 says exactly that, and matches the shape of a
            # fully-evaluated player - both mean "nothing for you to pay for".
            #
            # Logged because it is the case request IDs exist for: two
            # requests for one player, and only the other one queued anything.
            log.info(
                f"{pk} already has {already_queued} games in flight, queued nothing",
                extra={
                    "event": "analyse_already_queued",
                    "pk": pk,
                    "alreadyQueued": already_queued,
                },
            )
            return _response(
                202,
                {
                    "player": f"{platform}/{username}",
                    "queued": 0,
                    "skipped": skipped,
                    "byClass": per_class,
                    "excluded": excluded,
                    "alreadyQueued": already_queued,
                    "statusUrl": f"/player/{platform}/{username}",
                },
            )

    # Charged only now, and only if there is real work. Selection has already
    # skipped games evaluated at this depth, so a player who is fully analysed
    # reaches here with an empty todo and pays nothing - which is what keeps
    # re-submission free and is the reason verification could be cut.
    if todo:
        allowed, retry_after = take_token(user_id)
        if not allowed:
            # Nothing was queued, so the claim written moments ago describes a
            # run that is not happening. Leaving it would lock the player out
            # for the full window on a request that did no work - and the user
            # would be told to come back later twice over.
            release_claim(pk)
            return _response(
                429,
                {
                    "error": "rate limit exceeded",
                    "hint": (
                        "Analysing a new player is limited per account. "
                        "Already-analysed players are always free."
                    ),
                    "retryAfter": retry_after,
                },
            )

    queued = fan_out(pk, todo, user_id, context.aws_request_id)
    log.info(
        f"queued {queued} games for {pk}, skipped {skipped}",
        extra={
            "event": "analyse_queued",
            "pk": pk,
            "queued": queued,
            "skipped": skipped,
            "requestedBy": user_id,
        },
    )

    # 202: the work is queued, not done. The client polls the player route,
    # where evaluated games gain their own statistics group as they land -
    # the same progressive shape ingestion already uses.
    #
    # `skipped` is what makes re-analysing nearly free, and saying so out loud
    # is what makes the saving visible rather than merely claimed - the same
    # reason the ETag path reports its hits.
    return _response(
        202,
        {
            "player": f"{platform}/{username}",
            "queued": queued,
            "skipped": skipped,
            "byClass": per_class,
            # Not a saving and not a backlog: games that will never be
            # evaluated by design. Reported so a player whose history is
            # mostly correspondence gets an explanation rather than a
            # suspiciously small queued count. Exact over the whole history
            # now that it comes from the month summaries - `excludedPartial`,
            # which flagged a partial count, is no longer sent.
            "excluded": excluded,
            "statusUrl": f"/player/{platform}/{username}",
        },
    )
