# Slim base: the worker is one file, boto3, and the standard library. Chess.com
# is fetched with urllib rather than requests - one GET does not justify a
# dependency, and conditional requests are stdlib-native.
#
# Stockfish arrived in Phase E, as anticipated. The two workers have opposite
# constraints and that is why they are separate processes: ingestion is pinned
# to one task to protect Chess.com's API, while evaluation reads stored PGNs,
# makes no upstream requests, and scales freely.
#
# Every version is pinned, to what the image ran before pinning (read from
# its layers, 30 Sep 2026). python:3.13-slim follows Debian's current
# release, so an unpinned rebuild could move Stockfish by major versions and
# change every evaluation with no code change - and CI rebuilds on every
# worker change. The digest fixes the base exactly; the cost is that Debian
# security updates arrive only when this line is bumped, acceptable for a
# task with no inbound rules. Bump deliberately, and expect evaluations to
# shift when Stockfish does.
FROM python:3.13.15-slim-trixie@sha256:7c61056e61ac89e852de05f3dc6fa51a6dd2181797bceed46aa725dd7cb2cd3b

# Stockfish for the evaluator. One image serves both workers - the task
# definition picks which by overriding the command - because they share the
# table, the row shape and most of their operational story. Two images would
# be two things to keep in step for one differing line.
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends stockfish=17-1 \
    && rm -rf /var/lib/apt/lists/*

# python-chess parses PGNs and speaks UCI to the engine. Both are real work
# with real edge cases (annotations, variations, mate scores) and neither is
# worth hand-rolling. Versions, transitive ones included, in requirements.txt.
COPY requirements.txt ./
RUN pip install --no-cache-dir --no-deps -r requirements.txt && pip check

WORKDIR /app
COPY worker.py evaluator.py jsonlog.py ./

# -u: unbuffered stdout so logs reach CloudWatch as they happen, not when
# the buffer flushes (which for a crashed task is never).
CMD ["python", "-u", "worker.py"]
