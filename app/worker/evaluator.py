"""Evaluation worker: Stockfish over one player's recent games.

Separate from the ingestion worker, and the separation is the point. Ingestion
is pinned to one task because Chess.com's rule is phrased per *caller* and the
failure mode is an IP ban that money cannot undo. This worker reads PGNs that
are already stored and runs a local binary, so it makes **zero upstream
requests** and that constraint simply does not apply to it. It scales to
whatever is paid for.

One message is one player. The worker selects the last GAMES_PER_CLASS games in
each time control, skips any that already carry evals, and evaluates the rest.

Why bounded rather than everything: at depth 18 a game is ~56 seconds of one
vCPU. A player with 129,391 games would be months of compute; the same player
capped at 100 per control is 318 games and about five minutes on ten workers.
Bounding the *games* is what makes full depth affordable - bounding the depth
instead was measured and does not work, see CLAUDE.md.
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

TABLE_NAME = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["EVAL_QUEUE_URL"]
ENGINE_PATH = os.environ.get("STOCKFISH_PATH", "/usr/games/stockfish")

# Chess.com's own Game Review runs 18-30 depending on membership tier. 18 was
# chosen by measurement, not by matching them: benchmarked over 1,047 plies,
# depth 8 recalls 53% of depth-18's blunders and reports half the true average
# centipawn loss, and depth 12 reaches 65%. A cheap number nobody can trust is
# not a saving.
DEPTH = int(os.environ.get("EVAL_DEPTH", "18"))

# Per time control, newest first. Overall would be wrong: a player's last 100
# games can be entirely one control, hiding the rest of their play.
GAMES_PER_CLASS = int(os.environ.get("EVAL_GAMES_PER_CLASS", "100"))

# Centipawn thresholds. The exact numbers matter less than applying them
# consistently - what a dashboard needs is which moves were bad, not agreement
# with anyone else's labelling.
BLUNDER = 300
MISTAKE = 100
INACCURACY = 50

table = boto3.resource("dynamodb").Table(TABLE_NAME)
sqs = boto3.client("sqs")

_stop = False


def _on_sigterm(signum, frame):
    """Fargate sends SIGTERM before stopping a task. Finish the game in hand
    rather than dying mid-evaluation and replaying the whole message."""
    global _stop
    print("SIGTERM received, finishing current game", flush=True)
    _stop = True


def classify(loss):
    if loss >= BLUNDER:
        return "blunder"
    if loss >= MISTAKE:
        return "mistake"
    if loss >= INACCURACY:
        return "inaccuracy"
    return "ok"


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
        evals.append(info["score"].pov(board.turn).score(mate_score=10000))

    losses = []
    for i in range(len(evals) - 1):
        losses.append(max(0, evals[i] - (-evals[i + 1])))

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
    for ply, loss in mine:
        label = classify(loss)
        if label in counts:
            counts[label] += 1
        if worst is None or loss > worst[1]:
            worst = (ply, loss)

    return {
        "evals": evals,
        "acpl": int(sum(my_losses) / len(my_losses)) if my_losses else 0,
        "blunders": counts["blunder"],
        "mistakes": counts["mistake"],
        "inaccuracies": counts["inaccuracy"],
        "worstPly": worst[0] if worst else None,
        "worstLoss": worst[1] if worst else None,
        "depth": DEPTH,
    }


def select_games(pk):
    """The last GAMES_PER_CLASS games per time control that still need evals.

    Reads newest-first and stops adding to a control once it is full, so a
    player with 65,000 blitz games is read but only 100 are kept. Games that
    already carry evals count towards the cap without being re-evaluated -
    that is what makes a re-submit nearly free, and it must be per *game*
    rather than per player: a player analysed last month has 100 evaluated
    games, but their newest 100 now includes newer ones.
    """
    per_class = {}
    todo = []
    skipped = 0

    kwargs = {
        "KeyConditionExpression": Key("PK").eq(pk) & Key("SK").begins_with("GAME#"),
        "ScanIndexForward": False,  # newest archives first
        "ProjectionExpression": "SK, #c, pgn, colour, evalDepth",
        "ExpressionAttributeNames": {"#c": "class"},
    }
    while True:
        page = table.query(**kwargs)
        for item in page.get("Items", []):
            klass = item.get("class") or "unknown"
            seen = per_class.get(klass, 0)
            if seen >= GAMES_PER_CLASS:
                continue
            per_class[klass] = seen + 1
            if item.get("evalDepth") == DEPTH:
                skipped += 1
                continue
            if not item.get("pgn"):
                continue
            todo.append(item)
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    return todo, skipped, per_class


def process(message):
    body = json.loads(message["Body"])
    platform = body["platform"]
    username = body["username"]
    pk = f"PLAYER#{platform}#{username}"

    todo, skipped, per_class = select_games(pk)
    print(
        f"evaluating {platform}/{username}: {len(todo)} games "
        f"({skipped} already done) {dict(per_class)}",
        flush=True,
    )
    if not todo:
        return

    # One engine process for the whole message. Starting Stockfish per game
    # would throw away the warm process that is the stated reason this runs on
    # Fargate rather than Lambda.
    engine = chess.engine.SimpleEngine.popen_uci(ENGINE_PATH)
    engine.configure({"Threads": 1, "Hash": 128})
    done = 0
    try:
        for item in todo:
            if _stop:
                print("stopping early, message will replay", flush=True)
                break
            result = evaluate_game(engine, item["pgn"], item.get("colour", "w"))
            if result is None:
                # An unparseable game is marked rather than retried forever:
                # it will never parse, so leaving it unmarked would mean
                # re-attempting it on every future submit.
                table.update_item(
                    Key={"PK": pk, "SK": item["SK"]},
                    UpdateExpression="SET evalError = :e, evalDepth = :d",
                    ExpressionAttributeValues={":e": "unparseable pgn", ":d": DEPTH},
                )
                continue

            # One write per game. A game is the unit of work here, so a crash
            # loses at most the game in hand and the rest stay evaluated.
            table.update_item(
                Key={"PK": pk, "SK": item["SK"]},
                UpdateExpression=(
                    "SET evals = :e, acpl = :a, blunders = :b, mistakes = :m, "
                    "inaccuracies = :i, worstPly = :wp, worstLoss = :wl, "
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
                    ":d": DEPTH,
                    ":t": int(time.time()),
                },
            )
            done += 1
            if done % 25 == 0:
                print(f"  {done}/{len(todo)}", flush=True)
    finally:
        engine.quit()

    print(f"done {platform}/{username}: {done} games evaluated", flush=True)


def main():
    signal.signal(signal.SIGTERM, _on_sigterm)
    print(f"evaluator up, depth {DEPTH}, polling", flush=True)

    while not _stop:
        response = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,
        )
        for message in response.get("Messages", []):
            try:
                process(message)
            except Exception as exc:  # noqa: BLE001
                # Leave it for retry, then the DLQ. Same standard as the
                # ingestion worker: a generic failure must not silently
                # disappear.
                print(f"failed, leaving for retry/DLQ: {exc}", flush=True)
                continue
            sqs.delete_message(
                QueueUrl=QUEUE_URL,
                ReceiptHandle=message["ReceiptHandle"],
            )

    print("exiting cleanly", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
