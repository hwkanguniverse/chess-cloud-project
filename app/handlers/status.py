"""Status handler: one month, with its games.

The narrow read. Submit takes a username and fans out into ~200 months, so
what a client polls after submitting is the *player* route - see player.py,
which lists every month with its status and cumulative totals. This route is
what that page drills into: a single player-month, including the per-game
summary rows the player route deliberately projects away.

One GetItem, no index, no scan - the id carries both halves of the primary
key, which is the whole reason it looks the way it does.

Analysis is public and this route is unauthenticated. That is a product
decision, not an oversight - the point of the app is looking at a player's
skill across many games, so anyone may read anyone's profile. The underlying
data comes from Chess.com's Published Data API, which serves it without a
token, so requiring one here would protect nothing that is not already open.

Consequences worth knowing: reads are not attributable to a user, and the
stage throttle is the only thing bounding this route. Both are accepted - see
the decision log in PHASE-3.md.
"""

import json
import os
import re
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

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


def _read_games(pk, archive):
    """Every game item for one month, oldest first.

    Paginated because a Query caps at 1MB and a heavy month is ~2.5MB of game
    items - the same limit that silently truncated the player route in Phase 3,
    which is why this loops rather than reading one page and trusting it.
    """
    games = []
    kwargs = {
        "KeyConditionExpression": Key("PK").eq(pk)
        & Key("SK").begins_with(f"GAME#{archive}#"),
    }
    while True:
        page = table.query(**kwargs)
        for row in page.get("Items", []):
            row.pop("PK", None)
            row.pop("SK", None)
            games.append(row)
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    return games


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

    pk = f"PLAYER#{platform}#{username}"
    result = table.get_item(Key={"PK": pk, "SK": f"ARCHIVE#{archive}"})
    item = result.get("Item")
    if not item:
        return _response(404, {"error": "analysis not found"})

    # Games live in their own items. A month written before that change still
    # carries an inline `games` array, so the stored array wins when present
    # and the Query only runs for months in the new shape. Both shapes read
    # identically from the client's side, which is what lets the migration run
    # in the background instead of as a flag day.
    if "games" in item:
        games = item.pop("games")
    else:
        games = _read_games(pk, archive)

    # Return the item as stored, minus the key attributes and the requester.
    # PK/SK are storage layout, not API surface, and requestedBy is an internal
    # attribution note - exposing it would leak one user's activity to another
    # on what is otherwise public data.
    item.pop("PK", None)
    item.pop("SK", None)
    item.pop("requestedBy", None)
    item["id"] = analysis_id
    item["games"] = games
    return _response(200, item)
