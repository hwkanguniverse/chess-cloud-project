# Slim base: the worker is one file and boto3. Stockfish lands here in
# Phase 3 as an apt/copy layer; the image stays this shape.
FROM python:3.13-slim

RUN pip install --no-cache-dir boto3

WORKDIR /app
COPY worker.py .

# -u: unbuffered stdout so logs reach CloudWatch as they happen, not when
# the buffer flushes (which for a crashed task is never).
CMD ["python", "-u", "worker.py"]
