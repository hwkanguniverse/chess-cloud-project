# Slim base: the worker is one file, boto3, and the standard library. Chess.com
# is fetched with urllib rather than requests - one GET does not justify a
# dependency, and conditional requests are stdlib-native.
#
# Stockfish arrived in Phase E, as anticipated. The two workers have opposite
# constraints and that is why they are separate processes: ingestion is pinned
# to one task to protect Chess.com's API, while evaluation reads stored PGNs,
# makes no upstream requests, and scales freely.
FROM python:3.13-slim

# Stockfish for the evaluator. One image serves both workers - the task
# definition picks which by overriding the command - because they share the
# table, the row shape and most of their operational story. Two images would
# be two things to keep in step for one differing line.
RUN apt-get update -qq \
    && apt-get install -y -qq --no-install-recommends stockfish \
    && rm -rf /var/lib/apt/lists/*

# python-chess parses PGNs and speaks UCI to the engine. Both are real work
# with real edge cases (annotations, variations, mate scores) and neither is
# worth hand-rolling.
RUN pip install --no-cache-dir boto3 chess

WORKDIR /app
COPY worker.py evaluator.py jsonlog.py ./

# -u: unbuffered stdout so logs reach CloudWatch as they happen, not when
# the buffer flushes (which for a crashed task is never).
CMD ["python", "-u", "worker.py"]
