"""Players handler: the directory of everyone who has been analysed.

This is the one read in the project with no partition key behind it. Every
other route starts from a player the caller already named - "list all players"
does not, so there is no key to query by, and it Scans.

It used to Scan the *table*, which PHASE-3 accepted as temporary: a Scan reads
every item to find the few that match, so its cost grew with games ingested,
not with players. Once games became their own items that stopped being
theoretical - on 30 Sep the table held 203 month items among 83,427, the
20-page limit below stopped after two of the three players, and the page said
the list was incomplete. The one missing was hikaru, with 70,344 games. On the
index the same listing is one page, 9 read units, all three.

Now it Scans the `directory` index instead: every month item and nothing
else (see terraform/data), so the read is ~200 small entries however many
games exist. The deferral PHASE-3 chose - watch the Scan fail before adding
the index - is what happened.

Unauthenticated, like the other read routes: analysis is public shared data.
"""

import json
import os
from decimal import Decimal

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)

# A safety valve, not a feature. On the index a page is ~1 MB of ~100-byte
# month entries, so this is roughly 200,000 player-months before it trips. If
# it ever does, the route returns a partial list rather than paging forever
# inside a user-facing request - and `truncated` says so out loud, because the
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
    # The index holds month items only, so there is nothing to filter out -
    # the old table Scan needed a FilterExpression to drop the games, and still
    # paid to read every one of them first.
    scan = {
        "IndexName": "directory",
        "ProjectionExpression": "PK, #a, #s, summary.games, analysedAt",
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
                # Defensive: only month items carry `archive`, and they all
                # live under PLAYER#. Anything else is not a player.
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
