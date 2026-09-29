"""Worker: the consumer end of the pipeline.

Receives one player-month, fetches that archive from Chess.com, summarises it
and writes the result. One message, one HTTP request, one item - the mapping
the queue was designed around.

The unit of work is a player-month, not a game. Analysis is public and shared,
so it is keyed by the player it describes rather than by whoever asked for it -
which is what makes re-analysing a player someone else already ran unnecessary
rather than merely wasteful. Submit fans a username out into one message per
archive; this worker never sees the whole player.

There is no engine yet. "Analysed" means counted: games, results, colours,
time controls and rating range, plus a summary row per game. Full PGNs are not
stored and could not be - a heavy month is 3.4MB raw against DynamoDB's 400KB
item limit, while the summary rows for that same month are 197KB.

Ordering is the part that matters: the result is written BEFORE the message
is deleted. Crash between the two and the message reappears after the
visibility timeout and gets processed again - which is safe, because the fetch
is deterministic and the write overwrites the same item. That is at-least-once
delivery, and it is why no dedupe table exists.
"""

import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request

import boto3
from boto3.dynamodb.conditions import Key

from jsonlog import get_logger, log_context, message_fields

log = get_logger("worker")

QUEUE_URL = os.environ["QUEUE_URL"]
TABLE_NAME = os.environ["TABLE_NAME"]

# Chess.com's Published Data API is free and unauthenticated, so the only thing
# identifying us is this header. They try to reach the contact address before
# blocking an IP; without it the first warning is the block itself.
USER_AGENT = os.environ.get(
    "CHESSCOM_USER_AGENT",
    "chess-cloud-project/0.1 (learning project; wenkang.hoo@gmail.com)",
)

API_ROOT = "https://api.chess.com/pub"

# 429 is short-lived and self-clearing, so a brief in-process wait beats
# throwing the message back on the queue: the visibility timeout is minutes,
# the rate limit is seconds, and burning a receive on it moves the message
# closer to the DLQ for no reason.
RATE_LIMIT_RETRIES = 3
RATE_LIMIT_BACKOFF = 2  # seconds, doubled each attempt


class PermanentFailure(Exception):
    """The archive will never be fetchable, so retrying cannot help.

    404 and 410 both land here. Chess.com returns 404 for a deleted account
    and for a month its own archive list advertised but does not serve; 410
    means gone for good. None of them change on a retry, and letting them
    consume receives would put them in the DLQ looking exactly like a real
    outage - which would poison the one signal that means something is broken.
    """

    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason

sqs = boto3.client("sqs")
table = boto3.resource("dynamodb").Table(TABLE_NAME)

# ECS stops a task with SIGTERM and gives it 30s before SIGKILL. Finishing
# the current message first beats dying mid-write; a fetch is under a second,
# so the window is ample.
shutting_down = False


def _on_sigterm(signum, frame):
    global shutting_down
    shutting_down = True


signal.signal(signal.SIGTERM, _on_sigterm)


def fetch_archive(username, archive, etag):
    """GET one monthly archive, conditionally.

    Returns (games, new_etag) on a 200, or (None, etag) on a 304 meaning the
    archive is unchanged since the last fetch. The comparison happens on
    Chess.com's side: we send the stored validator and they decide. That is
    what makes an unchanged month cost 0.15s and no bytes instead of 0.8s and
    3.4MB - the saving this phase is built around.
    """
    year, month = archive.split("-")
    url = f"{API_ROOT}/player/{username}/games/{year}/{month}"

    headers = {"User-Agent": USER_AGENT}
    if etag:
        headers["If-None-Match"] = etag

    backoff = RATE_LIMIT_BACKOFF
    for attempt in range(RATE_LIMIT_RETRIES):
        request = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.loads(response.read())
                # Header lookup is case-insensitive here; Chess.com sends a
                # lowercase "etag", and reading it from a plain dict copy would
                # silently miss it and disable caching.
                return body.get("games", []), response.headers.get("ETag")
        except urllib.error.HTTPError as exc:
            if exc.code == 304:
                return None, etag

            if exc.code in (404, 410):
                # Store Chess.com's own message rather than inferring from the
                # code: 404 covers a deleted account and an unserved month, and
                # the body is the only thing that tells them apart.
                raise PermanentFailure(_upstream_message(exc)) from exc

            if exc.code == 429 and attempt < RATE_LIMIT_RETRIES - 1:
                log.warning(
                    f"429, backing off {backoff}s",
                    extra={"event": "rate_limited", "backoff_s": backoff},
                )
                time.sleep(backoff)
                backoff *= 2
                continue

            # 5xx, and a 429 that outlasted the backoff: transient. Raise and
            # let the queue's retry/DLQ path own it.
            raise

    raise RuntimeError("unreachable")


def _upstream_message(exc):
    """Chess.com's error text, for storing on a permanently failed item."""
    try:
        return json.loads(exc.read()).get("message") or f"HTTP {exc.code}"
    except (ValueError, OSError):
        return f"HTTP {exc.code}"


def summarise_game(game, username):
    """One row per game, with its moves.

    ~3.3KB each: a 138 B summary plus the PGN. The summary is what a player
    page lists; the PGN is what the evaluator reads. Storing it is what
    decouples evaluation from Chess.com - see the pgn field below.
    """
    white = game.get("white") or {}
    black = game.get("black") or {}
    playing_white = (white.get("username") or "").lower() == username
    me, them = (white, black) if playing_white else (black, white)

    return {
        "url": game.get("url"),
        "end": game.get("end_time"),
        # The moves, kept so evaluation never has to ask Chess.com again.
        # That is the whole reason the engine can run on more than one task:
        # the ingestion worker is pinned to protect their API, and an
        # evaluator that reads stored PGNs makes no upstream requests at all.
        # Measured at 3,151 B mean, which puts a game item at 0.8% of the
        # 400KB limit - affordable only because games became their own items.
        "pgn": game.get("pgn"),
        "colour": "w" if playing_white else "b",
        "result": me.get("result"),
        "rating": me.get("rating"),
        "opp": them.get("username"),
        "oppRating": them.get("rating"),
        "tc": game.get("time_control"),
        "class": game.get("time_class"),
        # No opening. Chess.com's "eco" field is a URL ending in the opening
        # *name*, not the ECO code - 66 characters in the worst case, which
        # made it the largest field in the row and a third of the item budget
        # for something nothing reads yet. Deferred, not rejected.
    }


# Chess.com reports a per-side result string. Only "win" is a win; everything
# else is a loss or one of several draw spellings, so draws are enumerated and
# the remainder is a loss.
DRAW_RESULTS = {
    "agreed",
    "repetition",
    "stalemate",
    "insufficient",
    "50move",
    "timevsinsufficient",
}


def aggregate(rows):
    """What "analysed" means without an engine: counts, not evaluations.

    Deliberately derived from the summary rows rather than the raw archive, so
    the stored aggregate can never disagree with the stored games.
    """
    totals = {
        "games": len(rows),
        "wins": 0,
        "losses": 0,
        "draws": 0,
        "asWhite": 0,
        "asBlack": 0,
        "byClass": {},
    }
    ratings = []

    for row in rows:
        result = row.get("result")
        if result == "win":
            totals["wins"] += 1
        elif result in DRAW_RESULTS:
            totals["draws"] += 1
        else:
            totals["losses"] += 1

        totals["asWhite" if row.get("colour") == "w" else "asBlack"] += 1

        time_class = row.get("class") or "unknown"
        totals["byClass"][time_class] = totals["byClass"].get(time_class, 0) + 1

        if row.get("rating"):
            ratings.append(row["rating"])

    if ratings:
        totals["ratingMin"] = min(ratings)
        totals["ratingMax"] = max(ratings)
        totals["ratingLast"] = ratings[-1]

    return totals


def _game_sk(archive, row):
    """Sort key for one game: GAME#<yyyy-mm>#<id>.

    The archive is *in* the key so a month's games stay contiguous and can be
    read with one begins_with Query. The id is the trailing path segment of
    the Chess.com game URL, which is stable and unique per game; a game with
    no URL falls back to its end time, which is not guaranteed unique but is
    the only other thing on the row that identifies it.
    """
    url = (row.get("url") or "").rstrip("/")
    game_id = url.rsplit("/", 1)[-1] if url else str(row.get("end") or "0")
    return f"GAME#{archive}#{game_id}"


def write_games(platform, username, archive, rows):
    """One item per game, replacing the games array that used to live on the
    month item.

    Why not one item per month: a game averages 177 plies, so per-ply
    evaluations are ~975KB for the heaviest real month against a 400KB item
    limit that is fixed and cannot be raised. Splitting by game puts each item
    at well under a kilobyte. It also fixes a limit already being approached
    without any engine - that month stored 2,815 games as ~380KB, 95% of the
    limit.

    Idempotent by key: a replayed message rewrites the same items with the
    same content. Stale games from a previous, longer fetch are deleted
    afterwards rather than left to accumulate, because a re-fetch can return
    fewer games than before - a game can be removed from an archive.
    """
    pk = f"PLAYER#{platform}#{username}"
    written = set()

    with table.batch_writer() as batch:
        for row in rows:
            sk = _game_sk(archive, row)
            written.add(sk)
            # classKey is the partition key of the by-class index, which is
            # how player.py and analyse.py find a player's newest 100 games in
            # one time control without reading the rest. Without it, a player
            # with 5 bullet games in 50,000 had their whole history read on
            # every page load, because bullet never reached its cap. Must
            # match scripts/backfill-class-key.py.
            class_key = f"{pk}#{row.get('class') or 'unknown'}"
            batch.put_item(Item={"PK": pk, "SK": sk, "classKey": class_key, **row})

    # Anything under this month's prefix that this fetch did not write is left
    # over from a previous one. Query for keys only - the games themselves are
    # not needed to decide what to remove.
    stale = []
    kwargs = {
        "KeyConditionExpression": Key("PK").eq(pk)
        & Key("SK").begins_with(f"GAME#{archive}#"),
        "ProjectionExpression": "SK",
    }
    while True:
        page = table.query(**kwargs)
        stale.extend(
            i["SK"] for i in page.get("Items", []) if i["SK"] not in written
        )
        if "LastEvaluatedKey" not in page:
            break
        kwargs["ExclusiveStartKey"] = page["LastEvaluatedKey"]

    if stale:
        log.info(
            f"removing {len(stale)} stale games from {archive}",
            extra={"event": "stale_games_removed", "archive": archive, "count": len(stale)},
        )
        with table.batch_writer() as batch:
            for sk in stale:
                batch.delete_item(Key={"PK": pk, "SK": sk})


def process(message):
    body = json.loads(message["Body"])
    analysis_id = body["id"]
    platform = body["platform"]
    username = body["username"]
    archive = body["archive"]

    key = {"PK": f"PLAYER#{platform}#{username}", "SK": f"ARCHIVE#{archive}"}

    # Read before fetching: the stored ETag is the only record that a previous
    # fetch happened, and the worker holds no state between messages. One
    # GetItem on the primary key against an HTTP request an order of magnitude
    # slower is noise beside what it saves.
    existing = table.get_item(Key=key).get("Item") or {}
    etag = existing.get("etag")

    log.info(
        f"fetching {analysis_id}" + (" (conditional)" if etag else ""),
        extra={"event": "fetch_start", "analysis_id": analysis_id, "conditional": bool(etag)},
    )
    try:
        games, new_etag = fetch_archive(username, archive, etag)
    except PermanentFailure as exc:
        # Terminal for this attempt, but not a verdict on the player: submit
        # lets a FAILED month be re-submitted, because a username can be
        # released and re-registered by someone else entirely.
        log.warning(
            f"permanent failure {analysis_id}: {exc.reason}",
            extra={"event": "permanent_failure", "analysis_id": analysis_id, "reason": exc.reason},
        )
        table.update_item(
            Key=key,
            UpdateExpression="SET #s = :s, #e = :e, checkedAt = :t",
            ExpressionAttributeNames={"#s": "status", "#e": "error"},
            ExpressionAttributeValues={
                ":s": "FAILED",
                ":e": exc.reason,
                ":t": int(time.time()),
            },
        )
        return

    if games is None:
        # 304: unchanged since last fetch. No parse, no aggregate, no games
        # written - only a note that it was checked, so the saving is visible
        # in the item rather than merely claimed.
        log.info(
            f"unchanged, skipping {analysis_id}",
            extra={"event": "archive_unchanged", "analysis_id": analysis_id},
        )
        table.update_item(
            Key=key,
            UpdateExpression="SET #s = :s, checkedAt = :t, lastCheckHit = :h",
            ExpressionAttributeNames={"#s": "status"},
            ExpressionAttributeValues={
                ":s": "COMPLETE",
                ":t": int(time.time()),
                ":h": True,
            },
        )
        return

    rows = [summarise_game(game, username) for game in games]
    totals = aggregate(rows)
    now = int(time.time())

    # Games go to their own items, then the month is marked COMPLETE. The
    # order is the durability argument, and it replaces the single-write one:
    # a crash between the two leaves the month not-COMPLETE with some game
    # items already written, so the message replays and overwrites them by the
    # same keys. A crash cannot leave COMPLETE visible without its games.
    #
    # The reverse order would be wrong in a way that is invisible until it
    # happens - COMPLETE with a partial or empty games list, and nothing to
    # say so.
    write_games(platform, username, archive, rows)

    table.update_item(
        Key=key,
        UpdateExpression=(
            "SET #s = :s, summary = :summary, "
            "etag = :etag, analysedAt = :t, checkedAt = :t, lastCheckHit = :h "
            "REMOVE games"
        ),
        ExpressionAttributeNames={"#s": "status"},
        ExpressionAttributeValues={
            ":s": "COMPLETE",
            ":summary": totals,
            ":etag": new_etag,
            ":t": now,
            ":h": False,
        },
    )
    log.info(
        f"done {analysis_id}: {totals['games']} games",
        extra={"event": "archive_done", "analysis_id": analysis_id, "games": totals["games"]},
    )


def main():
    log.info("worker up, polling", extra={"event": "worker_up"})
    while not shutting_down:
        resp = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,  # long poll; the idle loop costs one call per 20s
        )
        for message in resp.get("Messages", []):
            # Every line about this message - including the failure below -
            # carries the requestId of the submit that queued it.
            with log_context(**message_fields(message, analysis_id="id")):
                try:
                    process(message)
                except Exception as exc:  # noqa: BLE001
                    # Do NOT delete: leaving the message is what drives the retry
                    # counter, and after max receives the redrive policy moves it
                    # to the DLQ. Deleting here would silently discard the work.
                    log.exception(
                        f"failed, leaving for retry/DLQ: {exc}",
                        extra={"event": "message_failed"},
                    )
                    continue
                sqs.delete_message(
                    QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"]
                )
    log.info("SIGTERM received, exiting cleanly", extra={"event": "worker_exit"})
    return 0


if __name__ == "__main__":
    sys.exit(main())
