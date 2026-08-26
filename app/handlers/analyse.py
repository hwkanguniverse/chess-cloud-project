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

One message, one player. The evaluator does the selection, because which games
still need work is a question about the table rather than about the request.
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

    # The player must already be ingested. Evaluation reads stored PGNs, so
    # asking to analyse a player nobody has fetched is a request for work that
    # cannot be done - better a 404 here than a message that fails in the
    # worker and reaches the DLQ looking like a real fault.
    pk = f"PLAYER#{platform}#{username}"
    probe = table.query(
        KeyConditionExpression=Key("PK").eq(pk) & Key("SK").begins_with("GAME#"),
        Limit=1,
        ProjectionExpression="SK",
    )
    if not probe.get("Items"):
        return _response(
            404,
            {
                "error": "no games stored for this player",
                "hint": f"POST /games with {username} first",
            },
        )

    sqs.send_message(
        QueueUrl=EVAL_QUEUE_URL,
        MessageBody=json.dumps(
            {
                "platform": platform,
                "username": username,
                "requestedBy": user_id,
            }
        ),
    )

    # 202: the work is queued, not done. The client polls the player route,
    # where evaluated games gain their own statistics group as they land -
    # the same progressive shape ingestion already uses.
    return _response(
        202,
        {
            "player": f"{platform}/{username}",
            "queued": True,
            "statusUrl": f"/player/{platform}/{username}",
        },
    )
