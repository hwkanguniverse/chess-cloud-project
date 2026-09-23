"""Evaluation worker: Stockfish over one player's recent games.

Separate from the ingestion worker, and the separation is the point. Ingestion
is pinned to one task because Chess.com's rule is phrased per *caller* and the
failure mode is an IP ban that money cannot undo. This worker reads PGNs that
are already stored and runs a local binary, so it makes **zero upstream
requests** and that constraint simply does not apply to it. It scales to
whatever is paid for.

**One message is one game**, not one player, and that is what makes more
workers useful. Per player, a single message pinned an entire job to a single
task no matter how many were running - theohwk's 227 games took ~170 minutes
with a second evaluator sitting idle beside it. Per game, ten workers finish
the same job in ~17.

It also shortens every failure. The visibility timeout drops from seven hours
to five minutes, a crash loses one game rather than a whole player, and a
retry costs 45 seconds of Fargate instead of hours - which is what makes
quarantining a poison game cheap enough to be worth doing.

Selection lives in the analyse Lambda, which resolves a player into games and
fans out, exactly as submit resolves a player into archives. The worker no
longer decides what to evaluate; it evaluates what it is handed.

Why bounded rather than everything: at depth 18 a game is ~56 seconds of one
vCPU. A player with 129,391 games would be months of compute; capped at 100
per control it is 318 games. Bounding the *games* is what makes full depth
affordable - bounding the depth instead was measured and does not work, see
PHASE-E.md.
"""

import io
import json
import os
import signal
import sys
import time

import boto3
import chess
import chess.engine
import chess.pgn
from boto3.dynamodb.conditions import Key

from jsonlog import get_logger, log_context, message_fields

log = get_logger("evaluator")

TABLE_NAME = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["EVAL_QUEUE_URL"]
ENGINE_PATH = os.environ.get("STOCKFISH_PATH", "/usr/games/stockfish")

# Chess.com's own Game Review runs 18-30 depending on membership tier. 18 was
# chosen by measurement, not by matching them: benchmarked over 1,047 plies,
# depth 8 recalls 53% of depth-18's blunders and reports half the true average
# centipawn loss, and depth 12 reaches 65%. A cheap number nobody can trust is
# not a saving.
DEPTH = int(os.environ.get("EVAL_DEPTH", "18"))

# Centipawn thresholds. The exact numbers matter less than applying them
# consistently - what a dashboard needs is which moves were bad, not agreement
# with anyone else's labelling.
BLUNDER = 300
MISTAKE = 100
INACCURACY = 50

# What a mate is worth when forced onto the centipawn scale. Only ever used to
# store the raw eval; loss arithmetic clamps to CLAMP_CP below.
MATE_SCORE = 10000

# Evaluations are clamped to +/- this before computing centipawn loss. Roughly
# "a queen up and winning" - beyond it the position is decided and further
# engine advantage is not a meaningful difference in play quality. Lichess and
# most analysis tools clamp somewhere in this range for the same reason.
CLAMP_CP = 1000

# Centipawn loss is also bucketed across the course of the game, so a player can
# see *where* they go wrong rather than only how often.
#
# Buckets are a percentage of the game, not fixed move numbers, and that choice
# changed the answer. Measured over theohwk's 201 games: fixed boundaries
# (opening <= move 12, midgame <= move 30) said the midgame was worst at 92.0 cp.
# But **56% of games never reach move 31**, so that "endgame" figure was computed
# over 89 games rather than 201 - survivorship bias, and it flattered the endgame.
# By percentage every game contributes to every bucket, the move counts come out
# near-equal by construction, and the last third is worst at 90.9.
#
# Ten buckets rather than three because the shape is the interesting part: the
# loss curve rises steeply from ~15 cp and plateaus around ~90, which three bars
# cannot show. The reader can group them into phases by eye without this code
# having to claim which move an "endgame" starts at.
PHASE_BUCKETS = 10

table = boto3.resource("dynamodb").Table(TABLE_NAME)
sqs = boto3.client("sqs")

_stop = False


def _on_sigterm(signum, frame):
    """Fargate sends SIGTERM before stopping a task.

    Finish the game in hand rather than dying mid-evaluation. With one game per
    message that is at most ~45 seconds of work to protect, and the message is
    only deleted once the write succeeds - so a task killed mid-game simply
    replays it.
    """
    global _stop
    log.info("SIGTERM received, finishing current game", extra={"event": "sigterm"})
    _stop = True


def classify(loss):
    if loss >= BLUNDER:
        return "blunder"
    if loss >= MISTAKE:
        return "mistake"
    if loss >= INACCURACY:
        return "inaccuracy"
    return "ok"


def bucket_of(position, total):
    """Which tenth of the game a move falls in.

    `position` and `total` count the player's own moves, so the buckets mean
    the same thing for both colours and for games of any length.

    The final move lands in the last bucket rather than one past the end, which
    is what the min() guards - `position` runs to `total - 1`, but integer
    division still needs the clamp when total < PHASE_BUCKETS.
    """
    if total <= 0:
        return 0
    return min(PHASE_BUCKETS - 1, position * PHASE_BUCKETS // total)


def positions(pgn_text):
    """Every board position in the game, in order."""
    game = chess.pgn.read_game(io.StringIO(pgn_text))
    if game is None:
        return []
    board = game.board()
    boards = [board.copy()]
    for move in game.mainline_moves():
        board.push(move)
        boards.append(board.copy())
    return boards


def evaluate_game(engine, pgn_text, colour):
    """Per-ply evals and the mover's centipawn loss, for one game.

    Returns None if the PGN cannot be parsed - a single unreadable game must
    not fail the player, so the caller records it and moves on.
    """
    boards = positions(pgn_text)
    if len(boards) < 2:
        return None

    evals = []
    for board in boards:
        info = engine.analyse(board, chess.engine.Limit(depth=DEPTH))
        # From the point of view of the side to move, so a loss is always a
        # loss for whoever just moved regardless of colour.
        evals.append(info["score"].pov(board.turn).score(mate_score=MATE_SCORE))

    losses = []
    for i in range(len(evals) - 1):
        # Clamp before subtracting. A mate score is not a centipawn value on
        # the same scale - going from equal to "mate in 3" is not a 10,000
        # centipawn mistake - and subtracting one produces losses in the
        # thousands that then dominate the average.
        #
        # Found by measuring: 4 of the first 11 games came back with a worst
        # loss around 9,000-10,000, and the mean ACPL over those games was
        # 262 against 46 for the rest. A 5.7x distortion of the dashboard's
        # headline number, which is worse than the depth-8 error this project
        # already rejected on accuracy grounds.
        #
        # Clamping to CLAMP_CP means a position already lost stops accruing
        # further "loss" - which is right, because a player who is down a
        # queen cannot meaningfully blunder more of the same game away.
        before = max(-CLAMP_CP, min(CLAMP_CP, evals[i]))
        after = max(-CLAMP_CP, min(CLAMP_CP, -evals[i + 1]))
        losses.append(max(0, before - after))

    # Only the player's own moves count towards their statistics. White moves
    # on even plies, black on odd.
    mine = [
        (i, loss)
        for i, loss in enumerate(losses)
        if (i % 2 == 0) == (colour == "w")
    ]
    my_losses = [loss for _, loss in mine]

    counts = {"blunder": 0, "mistake": 0, "inaccuracy": 0}
    worst = None
    # Sums and counts per bucket, never averages. Averaging per-game averages
    # would weight a 12-move miniature the same as a 90-move grind; the reader
    # divides the summed loss by the summed count instead.
    phase_loss = [0] * PHASE_BUCKETS
    phase_count = [0] * PHASE_BUCKETS

    for position, (ply, loss) in enumerate(mine):
        label = classify(loss)
        if label in counts:
            counts[label] += 1
        if worst is None or loss > worst[1]:
            worst = (ply, loss)

        # Position within the player's *own* moves, not the raw ply index: a
        # player has half the plies, and bucketing on `ply` would put a black
        # player's moves systematically later in the game than a white one's.
        bucket = bucket_of(position, len(mine))
        phase_loss[bucket] += loss
        phase_count[bucket] += 1

    return {
        "evals": evals,
        "acpl": int(sum(my_losses) / len(my_losses)) if my_losses else 0,
        "blunders": counts["blunder"],
        "mistakes": counts["mistake"],
        "inaccuracies": counts["inaccuracy"],
        "worstPly": worst[0] if worst else None,
        "worstLoss": worst[1] if worst else None,
        "phaseLoss": phase_loss,
        "phaseCount": phase_count,
        "depth": DEPTH,
    }


def process(message):
    """Evaluate one game and write the result onto its item."""
    body = json.loads(message["Body"])
    pk = body["pk"]
    sk = body["sk"]

    item = table.get_item(
        Key={"PK": pk, "SK": sk},
        ProjectionExpression="pgn, colour, evalDepth",
    ).get("Item")

    if not item:
        # The game was deleted between fan-out and here - a re-fetch can drop
        # games that Chess.com no longer serves. Nothing to do, and nothing
        # wrong: acknowledge it rather than retrying into the DLQ.
        log.info(f"gone, skipping {sk}", extra={"event": "game_gone", "sk": sk})
        return

    if item.get("evalDepth") == DEPTH:
        # Already done at this depth. The Lambda filters these out when it
        # fans out, so reaching here means a duplicate delivery - which SQS
        # allows and which costs nothing to absorb.
        log.info(f"already evaluated {sk}", extra={"event": "game_already_evaluated", "sk": sk})
        return

    if not item.get("pgn"):
        log.warning(f"no pgn for {sk}", extra={"event": "game_no_pgn", "sk": sk})
        return

    # One engine process per message would start Stockfish per game and throw
    # away the warm process that is the stated reason this runs on Fargate
    # rather than Lambda. The module-level engine is started once per task and
    # reused across every message that task handles.
    engine = _engine()
    result = evaluate_game(engine, item["pgn"], item.get("colour", "w"))

    if result is None:
        # An unparseable game is marked rather than retried forever: it will
        # never parse, so leaving it unmarked means re-attempting it on every
        # future analyse.
        table.update_item(
            Key={"PK": pk, "SK": sk},
            UpdateExpression="SET evalError = :e, evalDepth = :d",
            ExpressionAttributeValues={":e": "unparseable pgn", ":d": DEPTH},
        )
        log.warning(f"unparseable {sk}", extra={"event": "game_unparseable", "sk": sk})
        return

    table.update_item(
        Key={"PK": pk, "SK": sk},
        UpdateExpression=(
            "SET evals = :e, acpl = :a, blunders = :b, mistakes = :m, "
            "inaccuracies = :i, worstPly = :wp, worstLoss = :wl, "
            "phaseLoss = :pl, phaseCount = :pc, "
            "evalDepth = :d, evaluatedAt = :t REMOVE evalError"
        ),
        ExpressionAttributeValues={
            ":e": result["evals"],
            ":a": result["acpl"],
            ":b": result["blunders"],
            ":m": result["mistakes"],
            ":i": result["inaccuracies"],
            ":wp": result["worstPly"],
            ":wl": result["worstLoss"],
            ":pl": result["phaseLoss"],
            ":pc": result["phaseCount"],
            ":d": DEPTH,
            ":t": int(time.time()),
        },
    )
    log.info(
        f"done {sk}: acpl={result['acpl']} blunders={result['blunders']}",
        extra={
            "event": "game_done",
            "sk": sk,
            "acpl": result["acpl"],
            "blunders": result["blunders"],
        },
    )


_engine_process = None


def _engine():
    """The task's Stockfish process, started on first use and kept warm.

    Reused across messages rather than per game. Starting the engine costs
    roughly a second and loading NNUE weights costs more, which would be a
    meaningful share of a 45-second job.
    """
    global _engine_process
    if _engine_process is None:
        _engine_process = chess.engine.SimpleEngine.popen_uci(ENGINE_PATH)
        _engine_process.configure({"Threads": 1, "Hash": 128})
    return _engine_process


def main():
    signal.signal(signal.SIGTERM, _on_sigterm)
    log.info(
        f"evaluator up, depth {DEPTH}, one game per message, polling",
        extra={"event": "evaluator_up", "depth": DEPTH},
    )

    while not _stop:
        # Ten at a time. Games are seconds of work each, so fetching one per
        # round trip would spend a real fraction of the time on SQS polling.
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=10,
            WaitTimeSeconds=20,
        )
        for message in response.get("Messages", []):
            if _stop:
                # The rest of the batch stays invisible until the visibility
                # timeout returns it, then another task picks it up.
                break
            # pk as well as sk: sk alone is GAME#<month>#<id> and does not
            # say whose game it is. requestedBy is the Cognito sub, so a
            # user's report of a bad run can be found without their requestId.
            fields = message_fields(
                message, pk="pk", sk="sk", requestedBy="requestedBy"
            )
            with log_context(**fields):
                try:
                    process(message)
                except Exception as exc:  # noqa: BLE001
                    # Leave it for retry, then the DLQ. Same standard as the
                    # ingestion worker: a generic failure must not silently
                    # disappear.
                    log.exception(
                        f"failed, leaving for retry/DLQ: {exc}",
                        extra={"event": "message_failed"},
                    )
                    continue
                # Deleted only after the write succeeded, so a crash mid-game
                # replays that one game rather than losing it.
                sqs.delete_message(
                    QueueUrl=QUEUE_URL,
                    ReceiptHandle=message["ReceiptHandle"],
                )

    if _engine_process is not None:
        _engine_process.quit()
    log.info("exiting cleanly", extra={"event": "evaluator_exit"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
