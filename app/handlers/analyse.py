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
import os
import re

import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ["TABLE_NAME"]
EVAL_QUEUE_URL = os.environ["EVAL_QUEUE_URL"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)
sqs = boto3.client("sqs")

PLATFORM_RE = re.compile(r"^(chesscom|lichess)$")
USERNAME_RE = re.compile(r"^[a-zA-Z0-9_-]{1,50}$")

# Per time control, newest first. Overall would be wrong: a player's last 100
# games can be entirely one control - theohwk's would be nearly all rapid,
# hiding 437 blitz games - so the cap is applied per control and the worst
# case is four controls of 100.
GAMES_PER_CLASS = int(os.environ.get("EVAL_GAMES_PER_CLASS", "100"))

# The depth the evaluator runs at. Duplicated here only to decide what still
# needs work; the worker owns the actual setting.
DEPTH = int(os.environ.get("EVAL_DEPTH", "18"))


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

    Reads newest-first and stops adding to a control once it is full, so a
    player with 65,000 blitz games is read but only 100 are kept.

    Games already evaluated at this depth count towards the cap without being
    re-queued. That is what makes re-analysing nearly free, and it has to be
    per *game* rather than per player: a player analysed last month has 100
    evaluated games, but their newest 100 now includes games played since, so
    a per-player check would never pick those up. The same insight as the
    ETag, one layer down.
    """
    per_class = {}
    todo = []
    skipped = 0
    seen_any = False

    kwargs = {
        "KeyConditionExpression": Key("PK").eq(pk) & Key("SK").begins_with("GAME#"),
        "ScanIndexForward": False,  # newest archives first
        # No pgn - the worker reads that itself. Pulling ~3KB per game here
        # just to discard it would make selection the expensive half of a
        # request that is meant to be cheap.
        "ProjectionExpression": "SK, #c, evalDepth",
        "ExpressionAttributeNames": {"#c": "class"},
    }
    while True:
        page = table.query(**kwargs)
        for item in page.get("Items", []):
            seen_any = True
            klass = item.get("class") or "unknown"
            seen = per_class.get(klass, 0)
            if seen >= GAMES_PER_CLASS:
                continue
            per_class[klass] = seen + 1
            if item.get("evalDepth") == DEPTH:
                skipped += 1
                continue
            todo.append(item["SK"])
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    return todo, skipped, per_class, seen_any


def fan_out(pk, sks, user_id):
    """One message per game, ten at a time.

    SendMessageBatch is a distinct IAM action from SendMessage rather than a
    variant of it - granting only the latter fails every fan-out with
    AccessDenied, which this project has already been caught by once.
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
                        {"pk": pk, "sk": sk, "requestedBy": user_id}
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
    todo, skipped, per_class, seen_any = select_games(pk)

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

    queued = fan_out(pk, todo, user_id)

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
            "statusUrl": f"/player/{platform}/{username}",
        },
    )
