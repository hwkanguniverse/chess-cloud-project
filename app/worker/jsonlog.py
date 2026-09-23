"""One JSON object per log line, for both workers.

Why JSON rather than prose: a metric filter on prose matches exact wording, so
rewording a message silently zeroes the metric and the alarm on it stays green
forever. A filter on `$.event` survives any change to the human text, which
stays in `message` so tailing is still readable.

The key names copy Lambda's native JSON log format (timestamp, level, message,
logger, and errorType/errorMessage/stackTrace for exceptions), so one Logs
Insights query works across the handlers and the workers alike.

Fields ride in on `extra=`: log.info("done", extra={"event": "game_done"}).
Fields that belong to every line about one message - above all the requestId
of the Lambda call that queued it - are set once with log_context() instead.
"""

import contextlib
import contextvars
import json
import logging
import sys
import time
import traceback

# Every attribute a bare LogRecord carries. Anything else on a record arrived
# through extra= and is a field to emit.
_RESERVED = set(vars(logging.makeLogRecord({}))) | {"message", "asctime", "taskName"}

_context = contextvars.ContextVar("log_context", default={})


@contextlib.contextmanager
def log_context(**fields):
    """Stamp these fields on every line logged inside the block.

    None values are dropped rather than written as null, so a message queued
    before request IDs existed - in flight during the deploy, or redriven from
    the DLQ later - logs without the field instead of with a misleading one.
    """
    token = _context.set(
        {**_context.get(), **{k: v for k, v in fields.items() if v is not None}}
    )
    try:
        yield
    finally:
        _context.reset(token)



def message_fields(message, **body_keys):
    """The log_context for one SQS message: its requestId and messageId, plus
    body_keys mapped as log_field="bodyKey".

    messageId is kept alongside requestId because SQS preserves it when a
    message moves to the DLQ, so even a message with no requestId can be tied
    back to the worker lines that failed it.

    A body that will not parse yields only messageId. process() raises on that
    same body, and its failure line still needs something to identify it.
    """
    try:
        body = json.loads(message.get("Body") or "")
    except ValueError:
        body = None
    if not isinstance(body, dict):
        body = {}
    return {
        "requestId": body.get("requestId"),
        "messageId": message.get("MessageId"),
        **{field: body.get(key) for field, key in body_keys.items()},
    }
class JsonFormatter(logging.Formatter):
    def format(self, record):
        entry = {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created))
            + f".{int(record.msecs):03d}Z",
            "level": record.levelname,
            "message": record.getMessage(),
            "logger": record.name,
            **_context.get(),
        }
        entry.update(
            (k, v) for k, v in vars(record).items() if k not in _RESERVED
        )
        if record.exc_info:
            etype, exc, tb = record.exc_info
            entry["errorType"] = etype.__name__
            entry["errorMessage"] = str(exc)
            entry["stackTrace"] = traceback.format_tb(tb)
        # default=str is the fallback for anything json cannot encode - a
        # DynamoDB Decimal, a set. A log line that cannot serialise raises only
        # when its path runs, and the failure path is the one that matters.
        return json.dumps(entry, default=str)


def get_logger(name):
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(logging.INFO)
    return logging.getLogger(name)
