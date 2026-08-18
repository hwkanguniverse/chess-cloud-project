"""Status handler: the read half of the front door.

The client polls this after a submit. One GetItem, no index, no scan - the id
carries both halves of the primary key, which is the whole reason it looks the
way it does.

Analysis is public: anyone may read any player's results. That is a product
decision, not an oversight - the point of the app is looking at a player's
skill across many games, and Chess.com's Published Data API is public anyway,
so there is nothing here that was not already readable upstream. The route
still sits behind the authorizer (see CLAUDE.md) so that reads are attributable
and rate-limited, but the *response* does not depend on who is asking.
"""

import json
import os
import re
from decimal import Decimal

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)

# platform/username/yyyy-mm - the three fields that name one unit of analysis.
ANALYSIS_ID_RE = re.compile(
    r"^(chesscom|lichess)/([a-z0-9_-]{1,50})/(\d{4}-(?:0[1-9]|1[0-2]))$"
)


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
    params = event.get("pathParameters") or {}
    # The id arrives as three path segments so that slashes inside it do not
    # have to be escaped by the client.
    analysis_id = "/".join(
        filter(None, [params.get("platform"), params.get("username"), params.get("archive")])
    )

    match = ANALYSIS_ID_RE.match(analysis_id)
    if not match:
        return _response(400, {"error": "malformed analysis id"})
    platform, username, archive = match.groups()

    result = table.get_item(
        Key={"PK": f"PLAYER#{platform}#{username}", "SK": f"ARCHIVE#{archive}"}
    )
    item = result.get("Item")
    if not item:
        return _response(404, {"error": "analysis not found"})

    # Return the item as stored, minus the key attributes and the requester.
    # PK/SK are storage layout, not API surface, and requestedBy is an internal
    # attribution note - exposing it would leak one user's activity to another
    # on what is otherwise public data.
    item.pop("PK", None)
    item.pop("SK", None)
    item.pop("requestedBy", None)
    item["id"] = analysis_id
    return _response(200, item)
