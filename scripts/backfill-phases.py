"""Fill in phaseLoss/phaseCount on games evaluated before those fields existed.

Why this needs no engine: `evaluate_game()` derives every loss figure from the
stored `evals` array and the player's colour. Stockfish is only needed to
*produce* `evals`, and `evals` is already on the item. So the phase split is
arithmetic over data the table already holds - no Fargate, no Stockfish, no
re-running 201 games at ~31 seconds each.

That claim is checked rather than asserted. For every game this recomputes
`acpl` from `evals` and compares it against the stored value. If they disagree,
this script's arithmetic has drifted from the evaluator's and the run aborts
without writing - because if acpl cannot be reproduced, neither can the phase
buckets that share the same loss loop.

Safe to re-run. A game that already carries `phaseCount` is skipped, so the
second run writes nothing - the same guard shape as `evalDepth == DEPTH` in the
evaluator.

Usage:
    python scripts/backfill-phases.py --dry-run
    python scripts/backfill-phases.py --player chesscom/theohwk
    python scripts/backfill-phases.py
"""

import argparse
import sys

import boto3
from boto3.dynamodb.conditions import Key

TABLE_NAME = "chess-cloud-games"

# Must match app/worker/evaluator.py. Duplicated rather than imported because
# the worker ships in a container and this runs from a laptop; the project
# already accepts this for EVAL_DEPTH and EVAL_CLASSES. The acpl self-check
# below is what catches it if these ever drift.
CLAMP_CP = 1000
PHASE_BUCKETS = 10


def bucket_of(position, total):
    """Must match bucket_of in app/worker/evaluator.py."""
    if total <= 0:
        return 0
    return min(PHASE_BUCKETS - 1, position * PHASE_BUCKETS // total)


def phases_from_evals(evals, colour):
    """Recompute the loss series, the phase buckets and acpl from stored evals.

    The loss arithmetic must match evaluate_game(): clamp both sides *before*
    subtracting, because a mate score is not a centipawn value on the same
    scale - the evaluator's comments record a 5.7x ACPL distortion from getting
    this wrong.
    """
    losses = []
    for i in range(len(evals) - 1):
        before = max(-CLAMP_CP, min(CLAMP_CP, evals[i]))
        after = max(-CLAMP_CP, min(CLAMP_CP, -evals[i + 1]))
        losses.append(max(0, before - after))

    mine = [
        loss
        for i, loss in enumerate(losses)
        if (i % 2 == 0) == (colour == "w")
    ]

    phase_loss = [0] * PHASE_BUCKETS
    phase_count = [0] * PHASE_BUCKETS
    for position, loss in enumerate(mine):
        bucket = bucket_of(position, len(mine))
        phase_loss[bucket] += loss
        phase_count[bucket] += 1

    acpl = int(sum(mine) / len(mine)) if mine else 0
    return phase_loss, phase_count, acpl, len(mine)


def backfill_player(table, pk, dry_run):
    written = skipped = no_evals = 0
    mismatches = []

    kwargs = {
        "KeyConditionExpression": Key("PK").eq(pk)
        & Key("SK").begins_with("GAME#"),
        # evals is the bulk of what this reads and the whole reason it can run
        # without the engine. Everything else is small.
        "ProjectionExpression": "SK, evals, colour, acpl, phaseCount, evalError",
    }
    while True:
        page = table.query(**kwargs)
        for item in page.get("Items", []):
            sk = item["SK"]

            # Already done, or nothing to do it from. An unparseable game has
            # evalError and no evals, and must stay that way.
            if "phaseCount" in item:
                skipped += 1
                continue
            if item.get("evalError") or "evals" not in item:
                no_evals += 1
                continue

            evals = [int(v) for v in item["evals"]]
            phase_loss, phase_count, acpl, moves = phases_from_evals(
                evals, item.get("colour", "w")
            )

            # The self-check. If this fails the arithmetic here no longer
            # matches the evaluator's, and the phase buckets cannot be trusted
            # either - so collect and abort rather than writing.
            stored = int(item.get("acpl", -1))
            if stored != acpl:
                mismatches.append((sk, acpl, stored))
                continue

            # Sums must reconcile with the whole-game figures, or a bucket has
            # been dropped or double-counted.
            assert sum(phase_count) == moves, f"{sk}: bucket counts lost moves"

            if not dry_run:
                table.update_item(
                    Key={"PK": pk, "SK": sk},
                    UpdateExpression=(
                        "SET phaseLoss = :pl, phaseCount = :pc"
                    ),
                    ExpressionAttributeValues={
                        ":pl": phase_loss,
                        ":pc": phase_count,
                    },
                )
            written += 1

        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    return written, skipped, no_evals, mismatches


def players(table, only):
    """Every player partition, or just the one asked for."""
    if only:
        return [f"PLAYER#{only.replace('/', '#')}"]

    seen = set()
    kwargs = {"ProjectionExpression": "PK"}
    while True:
        page = table.scan(**kwargs)
        for item in page.get("Items", []):
            if item["PK"].startswith("PLAYER#"):
                seen.add(item["PK"])
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]
    return sorted(seen)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--table", default=TABLE_NAME)
    ap.add_argument("--region", default="ap-southeast-1")
    ap.add_argument("--player", help="e.g. chesscom/theohwk")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    table = boto3.resource("dynamodb", region_name=args.region).Table(args.table)

    total_written = total_skipped = total_no_evals = 0
    all_mismatches = []

    for pk in players(table, args.player):
        written, skipped, no_evals, mismatches = backfill_player(
            table, pk, args.dry_run
        )
        if written or skipped or no_evals:
            print(
                f"{pk}: {written} to write, {skipped} already done, "
                f"{no_evals} without evals"
            )
        total_written += written
        total_skipped += skipped
        total_no_evals += no_evals
        all_mismatches += mismatches

    print()
    if all_mismatches:
        print(f"ABORTED: {len(all_mismatches)} games where recomputed acpl "
              f"disagrees with the stored value.")
        for sk, got, want in all_mismatches[:10]:
            print(f"  {sk}: recomputed {got}, stored {want}")
        print("\nThis script's loss arithmetic no longer matches "
              "app/worker/evaluator.py. Nothing was written for those games.")
        return 1

    verb = "would write" if args.dry_run else "wrote"
    print(f"{verb} {total_written}, skipped {total_skipped} already done, "
          f"{total_no_evals} had no evals")
    print(f"acpl self-check passed on all {total_written + total_skipped} "
          f"evaluated games")
    if args.dry_run:
        print("\ndry run - nothing written. Re-run without --dry-run.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
