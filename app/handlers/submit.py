"""Submit handler: the write half of the front door.

Accepts a game, records it as PENDING, queues it for analysis, and returns
202 with a URL to poll. It stays thin by design: analysis takes 30-90s and
API Gateway hard-caps every request at 29s, so "accepted, poll this" is the
only answer this function can ever give.
"""

import json
import os
import re
import time
import uuid

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["QUEUE_URL"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)
sqs = boto3.client("sqs")

# Letters, digits, underscore, hyphen - the characters Chess.com allows.
# Enforced here because the username becomes the first field of a
# hyphen-delimited id that travels in a URL path; anything outside this set
# would corrupt the id or the URL, not just look odd.
USERNAME_RE = re.compile(r"^[a-z0-9_-]{1,50}$")


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "request body must be JSON"})

    # Lowercased on the way in: Chess.com usernames are case-insensitive, and
    # the username is part of the partition key, where Hikaru and hikaru would
    # otherwise become two different users.
    username = str(body.get("username") or "").strip().lower()
    if not USERNAME_RE.match(username):
        return _response(
            400, {"error": "username is required: letters, digits, _ or - only"}
        )

    timestamp = int(time.time())
    # uuid4().hex, never str(uuid4()): the id is parsed with rsplit("-", 2),
    # so the gameId itself must contain no hyphens.
    game_id = uuid.uuid4().hex
    composite_id = f"{username}-{timestamp}-{game_id}"

    item = {
        "PK": f"USER#{username}",
        "SK": f"GAME#{timestamp}#{game_id}",
        "gameId": game_id,
        "username": username,
        "submittedAt": timestamp,
        "status": "PENDING",
    }
    pgn = body.get("pgn")
    if pgn:
        item["pgn"] = str(pgn)

    # Item first, then message. If the send fails the client gets a 500 and a
    # PENDING item exists with no message - visible in the table and harmless.
    # The other order can queue work for a game the table never heard of.
    table.put_item(Item=item)
    sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"id": composite_id}))

    domain = event["requestContext"]["domainName"]
    return _response(
        202,
        {
            "id": composite_id,
            "status": "PENDING",
            "statusUrl": f"https://{domain}/games/{composite_id}",
        },
    )