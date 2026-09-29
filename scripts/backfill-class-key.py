"""Add classKey to game items written before the by-class index existed.

Why: player.py and analyse.py find a player's newest 100 games per time
control through the by-class GSI, whose partition key is classKey. The index
is sparse, so a game without the attribute is invisible to it - an
un-backfilled player would read as having nothing evaluated and nothing to
queue. New games get it from the worker; this covers everything older.

Safe to re-run. It only touches game items that lack classKey, and the value
is derived from attributes already on the item, so a second run finds nothing
to do. The condition stops it resurrecting a game deleted mid-run (a re-fetch
removes games Chess.com no longer serves).

Usage:
    python scripts/backfill-class-key.py --dry-run
    python scripts/backfill-class-key.py
"""

import argparse
import collections
import sys
from concurrent.futures import ThreadPoolExecutor

import boto3
from botocore.config import Config
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

TABLE_NAME = "chess-cloud-games"


def class_key(pk, klass):
    """Must match write_games in app/worker/worker.py."""
    return f"{pk}#{klass or 'unknown'}"


def missing(table):
    """Every game item without classKey. A Scan, because this runs once over
    the whole table - there is no key that selects "games not yet backfilled"."""
    kwargs = {
        "FilterExpression": Attr("SK").begins_with("GAME#")
        & Attr("classKey").not_exists(),
        "ProjectionExpression": "PK, SK, #c",
        "ExpressionAttributeNames": {"#c": "class"},
    }
    while True:
        page = table.scan(**kwargs)
        yield from page.get("Items", [])
        if "LastEvaluatedKey" not in page:
            return
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]


def backfill(table, item):
    try:
        # Through the client, which is thread-safe; the Table resource is not.
        # The resource's client still takes plain Python values.
        table.meta.client.update_item(
            TableName=table.name,
            Key={"PK": item["PK"], "SK": item["SK"]},
            UpdateExpression="SET classKey = :k",
            ConditionExpression="attribute_exists(PK)",
            ExpressionAttributeValues={":k": class_key(item["PK"], item.get("class"))},
        )
        return "updated"
    except ClientError as exc:
        if exc.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return "gone"
        raise


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    # Adaptive retries, because the index throttles this and the default
    # retry budget runs out. Every update also writes the by-class index,
    # whose partition key is player + class - so one prolific player's games
    # all land on three index keys. The first run, at 16 threads, died on
    # hikaru's with ThrottlingException after ~66k of 83k: a hot key on the
    # index back-pressures writes to the table.
    config = Config(retries={"mode": "adaptive", "max_attempts": 25})
    table = boto3.resource("dynamodb", config=config).Table(TABLE_NAME)
    items = list(missing(table))

    per_player = collections.Counter(i["PK"] for i in items)
    for pk, n in sorted(per_player.items()):
        print(f"  {pk}: {n}")
    print(f"{len(items)} games without classKey")

    if args.dry_run or not items:
        return 0

    # Threads because each update is one round trip and there are ~83k of
    # them. Four, not sixteen: the ceiling is the hot index key described
    # above, not the round trip, so more threads only buy more throttling.
    with ThreadPoolExecutor(max_workers=4) as pool:
        results = collections.Counter(pool.map(lambda i: backfill(table, i), items))
    print(dict(results))

    left = sum(1 for _ in missing(table))
    print(f"{left} still without classKey")
    return 1 if left else 0


if __name__ == "__main__":
    sys.exit(main())
