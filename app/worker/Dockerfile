# Slim base: the worker is one file, boto3, and the standard library. Chess.com
# is fetched with urllib rather than requests - one GET does not justify a
# dependency, and conditional requests are stdlib-native.
#
# Stockfish lands here in Phase 4 as an apt/copy layer; the image stays this
# shape. (Phase 3 deliberately ships ingestion without an engine.)
FROM python:3.13-slim

RUN pip install --no-cache-dir boto3

WORKDIR /app
COPY worker.py .

# -u: unbuffered stdout so logs reach CloudWatch as they happen, not when
# the buffer flushes (which for a crashed task is never).
CMD ["python", "-u", "worker.py"]
