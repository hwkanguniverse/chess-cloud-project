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
per-month route is - see status.py and the decision log in PHASE-3.md.
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

# Evaluation state is *derived* from the game items, never stored on the month.
#
# "COMPLETE" has meant three different things across three phases - plumbing
# ran, then games counted, then games evaluated - and the month item could not
# say which. The fix is not another status value or a counter: `status` is the
# ingestion lifecycle and overloading it would drop months out of cumulative()
# (which filters on == "COMPLETE"), while a counter would have to be
# incremented by up to eight evaluators at once, breaking the recompute-never-
# accumulate rule that makes redelivery free.
#
# So it is computed here, from the same projected Query that analyse.py
# already runs to decide what to queue. It cannot drift from the game items
# because it *is* the game items.
DEPTH = int(os.environ.get("EVAL_DEPTH", "18"))

# Must match analyse.py's. If these disagree, this route reports games as
# outstanding that selection will never queue, and the dashboard shows a
# player as permanently part-evaluated.
EVAL_CLASSES = set(
    c.strip()
    for c in os.environ.get("EVAL_CLASSES", "bullet,blitz,rapid").split(",")
    if c.strip()
)
GAMES_PER_CLASS = int(os.environ.get("EVAL_GAMES_PER_CLASS", "100"))

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


def evaluation_state(pk):
    """What has been evaluated for this player, derived from the game items.

    Mirrors analyse.py's selection deliberately: newest-first, the same
    per-class cap, the same excluded controls. The point is that `outstanding`
    here equals what a POST /analyse would queue right now - if the two rules
    drifted, this route would show work pending that nothing will ever pick up.

    Reads only SK, class and evalDepth. The PGN is ~3KB per game and the evals
    array is larger still; projecting both away is what keeps this proportional
    to games rather than to bytes of chess.

    Returns evaluated/outstanding/excluded counts plus per-class detail, and
    `inScope` - the denominator a progress bar needs, since it is capped and so
    is not the player's total game count.
    """
    per_class = {}
    evaluated = 0
    outstanding = 0
    excluded = {}
    capped = False

    kwargs = {
        "KeyConditionExpression": Key("PK").eq(pk) & Key("SK").begins_with("GAME#"),
        "ScanIndexForward": False,
        "ProjectionExpression": "SK, #c, evalDepth",
        "ExpressionAttributeNames": {"#c": "class"},
    }
    while True:
        page = table.query(**kwargs)
        for item in page.get("Items", []):
            klass = item.get("class") or "unknown"

            if klass not in EVAL_CLASSES:
                excluded[klass] = excluded.get(klass, 0) + 1
                continue

            seen = per_class.get(klass, 0)
            if seen >= GAMES_PER_CLASS:
                continue
            per_class[klass] = seen + 1

            # evalDepth is set on success *and* on an unparseable game, which
            # is what stops a broken PGN being re-queued forever. Both count
            # as done here: neither will be attempted again.
            if item.get("evalDepth") == DEPTH:
                evaluated += 1
            else:
                outstanding += 1
        # Same early exit as analyse.py's selection, and for the same reason:
        # once every class is full, the rest of the partition is older than
        # everything already counted and cannot change the answer. Without it
        # this route read all 70,344 of Hikaru's games on every page load and
        # took 23 seconds against a 25s timeout.
        if all(per_class.get(c, 0) >= GAMES_PER_CLASS for c in EVAL_CLASSES):
            capped = True
            break

        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    return {
        "evaluated": evaluated,
        "outstanding": outstanding,
        "inScope": evaluated + outstanding,
        "byClass": per_class,
        "excluded": excluded,
        # Selection stopped early because every class was full, so `excluded`
        # counts what was seen rather than the player's whole history.
        "excludedPartial": capped,
        "depth": DEPTH,
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
            # The second statistics group. Always present, so a player who has
            # only been ingested reports a truthful zero rather than the
            # client having to infer absence - which is the ambiguity this
            # whole thing exists to remove.
            "evaluation": evaluation_state(f"PLAYER#{platform}#{username}"),
            "months": months,
        },
    )
