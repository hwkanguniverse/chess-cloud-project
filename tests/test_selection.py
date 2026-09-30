"""player.py and analyse.py must select the same games.

Each carries its own copy of the selection rule - newest GAMES_PER_CLASS per
evaluable class, from the by-class index - and each says it "must stay
identical" to the other. If they drift, /player shows games as outstanding
that /analyse will never queue, and a player reads as permanently
part-evaluated. This makes the comment executable.

Both handlers run against one fake table. The test asserts they send the
same queries and reach the same answer; it does not re-state the rule, so it
fails on drift between them rather than on a deliberate change to both.

Run: python -m unittest discover -s tests
"""

import importlib.util
import os
import pathlib
import unittest

HANDLERS = pathlib.Path(__file__).resolve().parent.parent / "app" / "handlers"
PK = "PLAYER#chesscom#someone"


def load(name):
    # Both modules build boto3 clients at import. Construction makes no call,
    # but needs a region and the env vars each reads unconditionally.
    os.environ.setdefault("AWS_DEFAULT_REGION", "ap-southeast-1")
    os.environ.setdefault("TABLE_NAME", "test-table")
    os.environ.setdefault("EVAL_QUEUE_URL", "https://example.invalid/queue")
    spec = importlib.util.spec_from_file_location(f"handler_{name}", HANDLERS / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def game(month, n, klass, depth=None):
    item = {"PK": PK, "SK": f"GAME#{month}#{n:05d}", "classKey": f"{PK}#{klass}"}
    if depth is not None:
        item["evalDepth"] = depth
    return item


class FakeTable:
    """Serves the two query shapes the handlers use, and records by-class
    queries so the two handlers' calls can be compared."""

    def __init__(self, games, months):
        self.games = games
        self.months = months
        self.index_calls = []

    def query(self, **kw):
        if kw.get("IndexName") == "by-class":
            self.index_calls.append(
                {k: v for k, v in kw.items() if k != "KeyConditionExpression"}
                | {"classKey": kw["KeyConditionExpression"].get_expression()["values"][1]}
            )
            key = self.index_calls[-1]["classKey"]
            # Sort key order, reversed for ScanIndexForward=False - what
            # DynamoDB does - then cut at Limit.
            rows = sorted(
                (g for g in self.games if g["classKey"] == key),
                key=lambda g: g["SK"],
                reverse=kw.get("ScanIndexForward", True) is False,
            )
            rows = rows[: kw.get("Limit", len(rows))]
            return {"Items": [{"SK": g["SK"], **({"evalDepth": g["evalDepth"]} if "evalDepth" in g else {})} for g in rows]}
        return {"Items": self.months}


def fixture():
    games = []
    # Blitz: more than the cap, newest partly evaluated, some at an old depth.
    for i in range(150):
        month = f"2026-{1 + i // 20:02d}"
        depth = 18 if i % 3 == 0 else (12 if i % 7 == 0 else None)
        games.append(game(month, i, "blitz", depth))
    # Bullet: under the cap - every game is in scope.
    for i in range(30):
        games.append(game("2026-05", 1000 + i, "bullet", 18 if i < 10 else None))
    # Daily: out of scope; must be neither queued nor counted as in scope.
    for i in range(12):
        games.append(game("2026-04", 2000 + i, "daily"))
    months = [
        {"summary": {"byClass": {"blitz": 150, "daily": 12}}},
        {"summary": {"byClass": {"bullet": 30, "daily": 0}}},
        {"summary": {}},
    ]
    return games, months


class SelectionAgrees(unittest.TestCase):
    def setUp(self):
        self.player = load("player")
        self.analyse = load("analyse")

    def run_both(self, games, months):
        self.player.table = FakeTable(games, months)
        self.analyse.table = FakeTable(games, months)
        state = self.player.evaluation_state(PK, months)
        todo, skipped, per_class, excluded, _ = self.analyse.select_games(PK)
        return state, (todo, skipped, per_class, excluded)

    def test_same_settings(self):
        for name in ("DEPTH", "EVAL_CLASSES", "GAMES_PER_CLASS"):
            self.assertEqual(getattr(self.player, name), getattr(self.analyse, name), name)

    def test_same_queries(self):
        self.run_both(*fixture())
        self.assertEqual(self.player.table.index_calls, self.analyse.table.index_calls)

    def test_same_answer(self):
        state, (todo, skipped, per_class, excluded) = self.run_both(*fixture())
        self.assertEqual(state["outstanding"], len(todo))
        self.assertEqual(state["evaluated"], skipped)
        self.assertEqual(state["byClass"], per_class)
        self.assertEqual(state["excluded"], excluded)
        # And the fixture actually exercised the cap, the partial class and
        # the exclusion - an agreement over nothing would prove nothing.
        self.assertEqual(per_class, {"blitz": 100, "bullet": 30})
        self.assertEqual(excluded, {"daily": 12})
        self.assertGreater(len(todo), 0)
        self.assertGreater(skipped, 0)

    def test_empty_player(self):
        state, (todo, skipped, per_class, excluded) = self.run_both([], [])
        self.assertEqual((state["outstanding"], state["evaluated"]), (0, 0))
        self.assertEqual((todo, skipped, per_class, excluded), ([], 0, {}, {}))


if __name__ == "__main__":
    unittest.main()
