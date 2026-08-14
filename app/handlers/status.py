"""Status handler: the read half of the front door.

The client polls this after a submit. One GetItem, no index, no scan - the
composite id carries both halves of the primary key, which is the whole
reason the id looks the way it does.
"""

import json
import os
from decimal import Decimal

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)


def _json_default(obj):
    # The resource API returns DynamoDB numbers as Decimal, which json.dumps
    # refuses to serialise.
    if isinstance(obj, Decimal):
        return int(obj) if obj % 1 == 0 else float(obj)
    raise TypeError(f"unserialisable type {type(obj)}")


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=_json_default),
    }


def handler(event, context):
    composite_id = (event.get("pathParameters") or {}).get("id", "")

    # rsplit("-", 2), never split("-"): usernames may contain hyphens, the
    # timestamp and gameId never do, so only the last two fields are safe to
    # take. This keeps a username like "a-b_c1" intact.
    parts = composite_id.rsplit("-", 2)
    if len(parts) != 3 or not all(parts) or not parts[1].isdigit():
        return _response(400, {"error": "malformed game id"})
    username, timestamp, game_id = parts

    result = table.get_item(
        Key={"PK": f"USER#{username}", "SK": f"GAME#{timestamp}#{game_id}"}
    )
    item = result.get("Item")
    if not item:
        return _response(404, {"error": "game not found"})

    # Return the item as stored, minus the key attributes - PK/SK are storage
    # layout, not API surface. The composite id already encodes them.
    item.pop("PK", None)
    item.pop("SK", None)
    item["id"] = composite_id
    return _response(200, item)