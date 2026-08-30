"""Delete every item in the games table.

Written for a deliberate full reset, not for routine use. The table has
prevent_destroy set - it outlives any terraform destroy - so clearing it means
deleting items, and there is no bulk "truncate" in DynamoDB.

Scan projects PK and SK only: BatchWriteItem needs the key and nothing else,
and pulling 30MB of PGNs across the wire to throw them away would be the
expensive way to do this.

Requires --yes to actually write. Without it this is a dry run that reports
what it would delete, which is the mode worth running first.
"""

import argparse
import sys

import boto3

BATCH = 25  # BatchWriteItem's hard limit


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", default="chess-cloud-games")
    ap.add_argument("--region", default="ap-southeast-1")
    ap.add_argument("--yes", action="store_true", help="actually delete")
    args = ap.parse_args()

    table = boto3.resource("dynamodb", region_name=args.region).Table(args.table)

    scanned = 0
    deleted = 0
    kinds = {}
    kwargs = {"ProjectionExpression": "PK, SK"}

    while True:
        page = table.scan(**kwargs)
        items = page.get("Items", [])
        scanned += len(items)

        for item in items:
            # Coarse breakdown so the dry run says what is about to go, rather
            # than only how much.
            kind = item["SK"].split("#", 1)[0]
            kinds[kind] = kinds.get(kind, 0) + 1

        if args.yes and items:
            with table.batch_writer() as writer:
                for item in items:
                    writer.delete_item(Key={"PK": item["PK"], "SK": item["SK"]})
                    deleted += 1
            print(f"deleted {deleted}/{scanned}", flush=True)

        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    print(f"\nscanned {scanned} items")
    for kind, count in sorted(kinds.items(), key=lambda kv: -kv[1]):
        print(f"  {kind:<12} {count}")

    if args.yes:
        print(f"\ndeleted {deleted}")
    else:
        print("\ndry run - nothing deleted. Pass --yes to delete.")
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
