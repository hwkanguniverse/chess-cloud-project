"""Player handler: the read half of the front door, for a whole player.

One Query on the player's partition returns every month that has been claimed
for them, newest first, each with its own status. Submit fans a username out
into ~150 independent months, so this is what makes that legible: months
appear as workers finish them, and a player with 40 of 152 done shows those 40
rather than nothing.

The cumulative totals are computed here rather than stored. They are
arithmetic over a Query the route already performs, so a stored running total
would add write contention between up to 150 concurrent workers and a drift
risk, in exchange for nothing. Computing on read is also correct for partial
progress by construction: the totals cover exactly the months that are done.

Analysis is public and this route is unauthenticated, for the same reason the
per-month route is - see status.py and the decision log in CLAUDE.md.
"""

import json
import os
import re
from decimal import Decimal

import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = os.environ["TABLE_NAME"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)

PLATFORM_RE = re.compile(r"^(chesscom|lichess)$")
USERNAME_RE = re.compile(r"^[a-z0-9_-]{1,50}$")

# Per-month fields returned in a player-level list. The games array is
# deliberately excluded: 828 games is 145KB, and ~200 of those months in one
# response would be hundreds of megabytes. Drill into a month for the games.
# Enforced in the Query's ProjectionExpression rather than filtered after the
# fact, so the games are never read at all.


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


def cumulative(months):
    """Totals across every COMPLETE month, from the per-month aggregates.

    Derived from the stored summaries rather than the games, so this can never
    disagree with what each month reports. Months still PENDING or FAILED
    contribute nothing - which is what makes a partial history readable rather
    than misleading.
    """
    totals = {
        "months": 0,
        "games": 0,
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "asWhite": 0,
        "asBlack": 0,
        "byClass": {},
    }
    ratings = []

    for month in months:
        summary = month.get("summary")
        if month.get("status") != "COMPLETE" or not summary:
            continue

        totals["months"] += 1
        for field in ("games", "wins", "losses", "draws", "asWhite", "asBlack"):
            totals[field] += int(summary.get(field, 0))

        for time_class, count in (summary.get("byClass") or {}).items():
            totals["byClass"][time_class] = totals["byClass"].get(
                time_class, 0
            ) + int(count)

        for field in ("ratingMin", "ratingMax"):
            if summary.get(field):
                ratings.append(int(summary[field]))

    if ratings:
        totals["ratingMin"] = min(ratings)
        totals["ratingMax"] = max(ratings)

    if totals["games"]:
        # Rounded to one decimal: this is a headline figure, not a statistic.
        totals["winRate"] = round(totals["wins"] / totals["games"] * 100, 1)

    return totals


def handler(event, context):
    params = event.get("pathParameters") or {}
    platform = (params.get("platform") or "").lower()
    username = (params.get("username") or "").lower()

    if not PLATFORM_RE.match(platform) or not USERNAME_RE.match(username):
        return _response(400, {"error": "malformed player id"})

    # One Query per page, no index, no scan - every month for a player shares
    # the partition key, which is exactly the read this layout was chosen for.
    # Descending so the newest month is first, which is what a page shows.
    #
    # Paginated, and that is not optional: DynamoDB caps a Query response at
    # 1MB, and a long-lived account exceeds that. Reading only the first page
    # returned 87 of erik's 230 months - with no error and totals that looked
    # entirely plausible, which is the failure worth guarding against.
    query = {
        "KeyConditionExpression": (
            Key("PK").eq(f"PLAYER#{platform}#{username}")
            & Key("SK").begins_with("ARCHIVE#")
        ),
        "ScanIndexForward": False,
        # The games array is the bulk of an item (145KB for a heavy month) and
        # nothing here reads it. Projecting it away is what keeps the page
        # count - and so the RCU cost - proportional to months rather than to
        # how much chess the player has played.
        "ProjectionExpression": "#a, #s, summary, #e, analysedAt, checkedAt",
        "ExpressionAttributeNames": {
            "#a": "archive",
            "#s": "status",
            "#e": "error",
        },
    }

    items = []
    while True:
        result = table.query(**query)
        items.extend(result.get("Items", []))
        last_key = result.get("LastEvaluatedKey")
        if not last_key:
            break
        query["ExclusiveStartKey"] = last_key

    if not items:
        # Never submitted. Distinct from a player who does not exist upstream -
        # that is submit's 404 to give, not this route's.
        return _response(404, {"error": "player not analysed"})

    # The projection already limited what came back, so the items are the
    # response shape.
    months = [dict(item) for item in items]
    pending = sum(1 for month in months if month.get("status") == "PENDING")

    return _response(
        200,
        {
            "player": f"{platform}/{username}",
            "totals": cumulative(months),
            # What the client polls on: non-zero means more months are coming.
            "pending": pending,
            "months": months,
        },
    )
