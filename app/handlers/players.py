"""Players handler: the directory of everyone who has been analysed.

This is the one read in the project with no partition key behind it. Every
other route starts from a player the caller already named - "list all players"
does not, so DynamoDB cannot answer it from the primary key and this Scan
reads the whole table.

That is a deliberate, temporary choice. At the current size (tens of players,
a few thousand items) a Scan is a handful of RCUs and costs nothing measurable.
It does not stay true: a Scan reads every item to find the few that match, so
its cost grows with total games ingested rather than with the number of
players - one busy player adds ~200 archive items that this route must read
and discard on every single call.

The replacement is a GSI keyed for listing, and it is planned rather than
hypothetical - see the decision log in CLAUDE.md. It was deferred so the
directory could be watched working (and watched getting slower) before the
index was added, rather than the index being asserted up front.

Unauthenticated, like the other read routes: analysis is public shared data.
"""

import json
import os
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Attr

TABLE_NAME = os.environ["TABLE_NAME"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)

# A safety valve, not a feature. If the table ever grows past this the route
# returns a partial list rather than paging forever inside a user-facing
# request - and `truncated` in the response says so out loud, because the
# player-route bug this project already hit was a *silent* truncation.
MAX_PAGES = 20


def _json_default(obj):
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
    # Projection matters more here than anywhere else in the project. Without
    # it the Scan pulls back every games array in the table - 145KB per heavy
    # month - to build a list that shows none of them. With it, DynamoDB still
    # *reads* the full items (a Scan's RCU cost is charged on what it reads,
    # not what it returns), but the response stays small and the Lambda is not
    # deserialising megabytes of JSON it will throw away.
    scan = {
        "ProjectionExpression": "PK, #a, #s, summary.games, analysedAt",
        # Months only. Games are their own items now, and a Scan sees every
        # item in the table - without this the month count becomes the game
        # count, which for a 129,391-game player is off by three orders of
        # magnitude. Filtered server-side so the games are not shipped back
        # here just to be discarded.
        "FilterExpression": Attr("SK").begins_with("ARCHIVE#"),
        "ExpressionAttributeNames": {"#a": "archive", "#s": "status"},
    }

    # Collapse the archive items down to one entry per player as they arrive.
    # Keyed by PK, which already encodes platform and username.
    players = {}
    truncated = False

    for page in range(MAX_PAGES + 1):
        if page == MAX_PAGES:
            truncated = True
            break

        result = table.scan(**scan)

        for item in result.get("Items", []):
            key = item.get("PK", "")
            if not key.startswith("PLAYER#"):
                # OAUTH# state and USER# link items share the table. The
                # directory is players only.
                continue

            parts = key.split("#")
            if len(parts) != 3:
                continue
            _, platform, username = parts

            entry = players.setdefault(
                f"{platform}/{username}",
                {
                    "platform": platform,
                    "username": username,
                    "months": 0,
                    "complete": 0,
                    "pending": 0,
                    "games": 0,
                    "lastAnalysedAt": None,
                },
            )

            entry["months"] += 1
            status = item.get("status")
            if status == "COMPLETE":
                entry["complete"] += 1
                # summary.games only exists on a month that actually ran, so
                # the projection returns `summary` as a dict with one key.
                entry["games"] += int((item.get("summary") or {}).get("games", 0))
            elif status == "PENDING":
                entry["pending"] += 1

            analysed = item.get("analysedAt")
            if analysed and (
                entry["lastAnalysedAt"] is None
                or int(analysed) > entry["lastAnalysedAt"]
            ):
                entry["lastAnalysedAt"] = int(analysed)

        last_key = result.get("LastEvaluatedKey")
        if not last_key:
            break
        scan["ExclusiveStartKey"] = last_key

    # Most recently analysed first: the directory's job is "what has this thing
    # been doing", so a player ingested five minutes ago is more interesting
    # than one from last month. Players with nothing complete sort last.
    listing = sorted(
        players.values(),
        key=lambda entry: (entry["lastAnalysedAt"] or 0),
        reverse=True,
    )

    return _response(
        200,
        {
            "players": listing,
            "count": len(listing),
            # True means the list is incomplete. Said explicitly because the
            # equivalent bug on the player route returned plausible-looking
            # totals with no indication anything was missing.
            "truncated": truncated,
        },
    )
