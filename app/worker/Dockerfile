# Slim base: the worker is one file, boto3, and the standard library. Chess.com
# is fetched with urllib rather than requests - one GET does not justify a
# dependency, and conditional requests are stdlib-native.
#
# Stockfish lands here in Phase E as an apt/copy layer; the image stays this
# shape. (Phase 3 deliberately ships ingestion without an engine, and Phase F
# puts a frontend in front of it - the engine's output is visual, so the page
# that displays it comes first.)
#
# Not Phase 4: the numbered phases map to certifications, and 4 is
# observability. The engine has no numbered phase in the roadmap at all -
# an earlier comment here said Phase 4 and was simply wrong.
FROM python:3.13-slim

RUN pip install --no-cache-dir boto3

WORKDIR /app
COPY worker.py .

# -u: unbuffered stdout so logs reach CloudWatch as they happen, not when
# the buffer flushes (which for a crashed task is never).
CMD ["python", "-u", "worker.py"]
