"""Move stored games out of month items and into one item per game.

Why: a month item holds every game as an inline array, and the heaviest real
month - danielnaroditsky 2024-03, 2,815 games - measures ~380KB against
DynamoDB's fixed 400KB item limit. That is 95% full with no engine involved,
and the next slightly heavier month fails to write with no failure path for it.
Per-ply evaluations (Phase E) would need ~975KB for that month, so they could
never have shared the item either.

Safe to re-run. Each month is: write the game items, then REMOVE the array.
A crash between the two leaves the array in place and the game items written,
which is exactly the state the reader already tolerates - status.py prefers the
inline array when present, so a half-migrated month still serves correctly.
Re-running finishes it.

Read-compatibility is what makes this a background job rather than a flag day:
    - month with `games` array  -> served from the array (old shape)
    - month without             -> served from a Query (new shape)

Usage:
    python scripts/migrate-games.py --dry-run
    python scripts/migrate-games.py --player chesscom/erik
    python scripts/migrate-games.py
"""

import argparse
import sys

import boto3
from boto3.dynamodb.conditions import Attr, Key

TABLE_NAME = "chess-cloud-games"


def game_sk(archive, row):
    """Must match _game_sk in app/worker/worker.py, or a re-fetch after the
    migration would write duplicates alongside the migrated rows instead of
    overwriting them."""
    url = (row.get("url") or "").rstrip("/")
    game_id = url.rsplit("/", 1)[-1] if url else str(row.get("end") or "0")
    return f"GAME#{archive}#{game_id}"


def migrate_month(table, item, dry_run):
    pk = item["PK"]
    sk = item["SK"]
    archive = sk.split("#", 1)[1]
    rows = item.get("games") or []

    if dry_run:
        keys = {game_sk(archive, r) for r in rows}
        return len(rows), len(rows) - len(keys)

    with table.batch_writer() as batch:
        for row in rows:
            batch.put_item(Item={"PK": pk, "SK": game_sk(archive, row), **row})

    # Only after every game is written. The array is the fallback the reader
    # depends on, so removing it first would blank the month for as long as the
    # writes took.
    table.update_item(
        Key={"PK": pk, "SK": sk},
        UpdateExpression="REMOVE games",
    )
    return len(rows), 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--player", help="platform/username, e.g. chesscom/erik")
    parser.add_argument("--table", default=TABLE_NAME)
    args = parser.parse_args()

    table = boto3.resource("dynamodb").Table(args.table)

    # Only months that still carry an inline array. Already-migrated months and
    # game items are skipped server-side, so a re-run costs a Scan and nothing
    # else.
    kwargs = {
        "FilterExpression": Attr("SK").begins_with("ARCHIVE#")
        & Attr("games").exists(),
    }
    if args.player:
        platform, _, username = args.player.partition("/")
        kwargs = {
            "KeyConditionExpression": Key("PK").eq(f"PLAYER#{platform}#{username}")
            & Key("SK").begins_with("ARCHIVE#"),
            "FilterExpression": Attr("games").exists(),
        }

    months = 0
    games = 0
    collisions = 0
    query = args.player is not None

    while True:
        page = table.query(**kwargs) if query else table.scan(**kwargs)
        for item in page.get("Items", []):
            n, dupes = migrate_month(table, item, args.dry_run)
            months += 1
            games += n
            collisions += dupes
            print(f"  {item['PK']} {item['SK']}: {n} games", flush=True)
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    verb = "would migrate" if args.dry_run else "migrated"
    print(f"\n{verb} {months} months, {games} games")
    if collisions:
        print(f"WARNING: {collisions} sort-key collisions - games would be lost")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
