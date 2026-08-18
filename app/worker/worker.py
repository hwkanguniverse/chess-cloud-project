"""Phase 1 fake worker: the consumer end of the pipeline.

Receives a message, sleeps 10 seconds, writes a hardcoded result, marks the
game COMPLETE, deletes the message. Nothing more - the sleep is a stand-in
for Stockfish so that any breakage in this phase is AWS plumbing, never AWS
plumbing and chess at once.

Ordering is the part that matters: the result is written BEFORE the message
is deleted. Crash between the two and the message reappears after the
visibility timeout and gets processed again - which is safe, because analysis
is deterministic and overwrites the same item. That is at-least-once
delivery, and it is why no dedupe table exists.
"""

import json
import os
import signal
import sys
import time

import boto3

QUEUE_URL = os.environ["QUEUE_URL"]
TABLE_NAME = os.environ["TABLE_NAME"]

sqs = boto3.client("sqs")
table = boto3.resource("dynamodb").Table(TABLE_NAME)

# ECS stops a task with SIGTERM and gives it 30s before SIGKILL. Finishing
# the current message first (10s fake, within the window) beats dying
# mid-write; with the real engine (30-90s) the message simply reappears
# after the visibility timeout, so abandoning it is also safe.
shutting_down = False


def _on_sigterm(signum, frame):
    global shutting_down
    shutting_down = True


signal.signal(signal.SIGTERM, _on_sigterm)


def process(message):
    body = json.loads(message["Body"])
    analysis_id = body["id"]

    # The key travels in the message rather than being parsed out of the id.
    # The unit of work is a player-month: analysis is public and shared, so it
    # is keyed by the player it describes, not by whoever asked for it.
    platform = body["platform"]
    username = body["username"]
    archive = body["archive"]

    print(f"analysing {analysis_id}", flush=True)
    time.sleep(10)  # stand-in for Stockfish

    table.update_item(
        Key={"PK": f"PLAYER#{platform}#{username}", "SK": f"ARCHIVE#{archive}"},
        UpdateExpression="SET #s = :s, #r = :r, analysedAt = :t",
        ExpressionAttributeNames={"#s": "status", "#r": "result"},
        ExpressionAttributeValues={
            ":s": "COMPLETE",
            ":r": {"fake": True, "accuracy": 42, "blunders": 0},
            ":t": int(time.time()),
        },
    )


def main():
    print("worker up, polling", flush=True)
    while not shutting_down:
        resp = sqs.receive_message(
            QueueUrl=QUEUE_URL,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20,  # long poll; the idle loop costs one call per 20s
        )
        for message in resp.get("Messages", []):
            try:
                process(message)
            except Exception as exc:  # noqa: BLE001
                # Do NOT delete: leaving the message is what drives the retry
                # counter, and after max receives the redrive policy moves it
                # to the DLQ. Deleting here would silently discard the game.
                print(f"failed, leaving for retry/DLQ: {exc}", flush=True)
                continue
            sqs.delete_message(
                QueueUrl=QUEUE_URL, ReceiptHandle=message["ReceiptHandle"]
            )
            print("done", flush=True)
    print("SIGTERM received, exiting cleanly", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
