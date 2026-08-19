"""Link handler: proving a user owns a chess account.

Cognito proves who someone is *here*. It says nothing about who they are on a
chess site, and the chess username on a submit is just a string the client
typed. Linking closes that gap where the platform allows it:

  - Lichess exposes OAuth2 with PKCE, open and unregistered, so the returned
    identity is trustworthy and the link is stored verified.
  - Chess.com's OAuth is approval-gated and the timeline is not ours, so the
    username is stored unverified. Analysis still works: the Published Data
    API is public, so ownership proves nothing the data does not already give.

Three routes:
  POST /link/lichess           start the flow, return an authorize URL
  GET  /link/lichess/callback  Lichess redirects the browser back here
  POST /link/chesscom          store an unverified username

The callback is the interesting one. It arrives as a plain browser redirect
with no Authorization header, so the gateway cannot tell us who it is. The
OAuth `state` parameter carries that: the start route writes state -> sub
before redirecting, and the callback reads it back. That item also holds the
PKCE verifier, and carries a TTL so an abandoned flow expires itself.
"""

import base64
import hashlib
import json
import os
import re
import secrets
import time
import urllib.parse
import urllib.request

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
# Public URL of this API. The redirect_uri must match byte-for-byte between the
# authorize request and the token exchange, so it is configured once here
# rather than rebuilt from the event in two places.
API_BASE = os.environ["API_BASE"]

table = boto3.resource("dynamodb").Table(TABLE_NAME)

LICHESS = "https://lichess.org"
# Any client_id works: Lichess does not require pre-registration for public
# PKCE clients. A descriptive one is what the user sees on the consent screen.
LICHESS_CLIENT_ID = "chess-cloud"

USERNAME_RE = re.compile(r"^[a-z0-9_-]{1,50}$")

# How long a started link flow stays valid. Long enough to log in and approve,
# short enough that an abandoned attempt is not sitting around for hours.
STATE_TTL_SECONDS = 600


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _html(status, message):
    """The callback lands in a browser, so it answers in HTML rather than JSON."""
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/html; charset=utf-8"},
        "body": f"<!doctype html><meta charset=utf-8><title>chess-cloud</title>"
        f"<body style='font-family:system-ui;padding:2rem'>{message}</body>",
    }


def _caller_sub(event):
    claims = (
        event.get("requestContext", {}).get("authorizer", {}).get("jwt", {})
    ).get("claims", {})
    return claims.get("sub")


def _pkce_pair():
    """A PKCE verifier and its S256 challenge.

    This is what replaces a client secret. The verifier is a random string kept
    server-side; only its SHA-256 hash travels in the authorize URL. An attacker
    who intercepts the returned code cannot exchange it without the verifier,
    which never left this account.
    """
    verifier = secrets.token_urlsafe(64)[:128]
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return verifier, challenge


def _post_json(url, payload):
    data = urllib.parse.urlencode(payload).encode("ascii")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            # Lichess asks that clients identify themselves so they can make
            # contact before blocking anything.
            "User-Agent": "chess-cloud (github.com/hoowenkang)",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def _get_json(url, token):
    req = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "User-Agent": "chess-cloud (github.com/hoowenkang)",
        },
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())


def _put_link(user_id, platform, username, verified):
    now = int(time.time())
    table.put_item(
        Item={
            "PK": f"USER#{user_id}",
            "SK": f"LINK#{platform}",
            "platform": platform,
            "username": username,
            # The whole point of the distinction: a verified link was proven by
            # the platform itself, an unverified one is the user's word.
            "verified": verified,
            "linkedAt": now,
        }
    )


# --- Lichess: start --------------------------------------------------------


def start_lichess(event):
    user_id = _caller_sub(event)
    if not user_id:
        return _response(401, {"error": "unauthenticated"})

    verifier, challenge = _pkce_pair()
    state = secrets.token_urlsafe(32)

    # state -> sub, written before the redirect. The callback has no token, so
    # this item is the only thing tying the returning browser to a user. It is
    # keyed under the user's own partition so an abandoned flow cannot pile up
    # anywhere unexpected, and it expires on its own.
    table.put_item(
        Item={
            "PK": f"USER#{user_id}",
            "SK": f"OAUTH#{state}",
            "codeVerifier": verifier,
            "platform": "lichess",
            "expiresAt": int(time.time()) + STATE_TTL_SECONDS,
        }
    )

    params = {
        "response_type": "code",
        "client_id": LICHESS_CLIENT_ID,
        "redirect_uri": f"{API_BASE}/link/lichess/callback",
        "code_challenge_method": "S256",
        "code_challenge": challenge,
        # No scope: reading the account's own username needs no permission
        # beyond identifying the user. Asking for more would be rude and would
        # widen the blast radius of a leaked token for no gain.
        "scope": "",
        "state": state,
    }
    return _response(
        200,
        {
            "authorizeUrl": f"{LICHESS}/oauth?" + urllib.parse.urlencode(params),
            "expiresIn": STATE_TTL_SECONDS,
        },
    )


# --- Lichess: callback -----------------------------------------------------


def callback_lichess(event):
    params = event.get("queryStringParameters") or {}
    state = params.get("state")
    code = params.get("code")

    # The user pressed "deny" on Lichess, or something upstream failed.
    if params.get("error"):
        return _html(400, f"<h1>Link cancelled</h1><p>{params['error']}</p>")
    if not state or not code:
        return _html(400, "<h1>Bad callback</h1><p>Missing code or state.</p>")

    # The state is unguessable, so finding it proves this callback belongs to a
    # flow we started. A scan is acceptable here only because the table is
    # tiny and this runs once per link; if it ever grows, the state item wants
    # its own partition rather than a GSI on a one-shot lookup.
    found = table.scan(
        FilterExpression="SK = :sk",
        ExpressionAttributeValues={":sk": f"OAUTH#{state}"},
        Limit=1,
    ).get("Items", [])
    if not found:
        return _html(400, "<h1>Link expired</h1><p>Start the link again.</p>")

    pending = found[0]
    # TTL deletion is asynchronous and can lag by up to ~48h, so an expired
    # item may still be sitting there. Check the time rather than trusting the
    # sweep to have run.
    if int(pending.get("expiresAt", 0)) < int(time.time()):
        return _html(400, "<h1>Link expired</h1><p>Start the link again.</p>")

    user_id = pending["PK"].split("#", 1)[1]

    try:
        token_response = _post_json(
            f"{LICHESS}/api/token",
            {
                "grant_type": "authorization_code",
                "code": code,
                "code_verifier": pending["codeVerifier"],
                "redirect_uri": f"{API_BASE}/link/lichess/callback",
                "client_id": LICHESS_CLIENT_ID,
            },
        )
        account = _get_json(f"{LICHESS}/api/account", token_response["access_token"])
    except Exception as exc:  # noqa: BLE001 - surface upstream failures as one 502
        print(f"lichess exchange failed: {exc}")
        return _html(502, "<h1>Link failed</h1><p>Lichess did not respond.</p>")

    username = str(account.get("username", "")).lower()
    if not USERNAME_RE.match(username):
        return _html(502, "<h1>Link failed</h1><p>Unexpected account response.</p>")

    _put_link(user_id, "lichess", username, verified=True)

    # One-shot: consume the state so the same callback cannot be replayed.
    table.delete_item(Key={"PK": pending["PK"], "SK": pending["SK"]})

    return _html(
        200,
        f"<h1>Linked</h1><p>Lichess account <strong>{username}</strong> "
        f"is now linked and verified. You can close this tab.</p>",
    )


# --- Chess.com: unverified placeholder -------------------------------------


def link_chesscom(event):
    """Store a Chess.com username without proof of ownership.

    Chess.com's OAuth is approval-gated, aimed at connected-board and login
    integrations, and the timeline is not ours. Rather than block on someone
    else's queue, the username is stored unverified - which is honest, and
    costs nothing because the Published Data API is public. If approval ever
    lands, this becomes a real OAuth flow and existing links get upgraded.
    """
    user_id = _caller_sub(event)
    if not user_id:
        return _response(401, {"error": "unauthenticated"})

    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "request body must be JSON"})

    username = str(body.get("username") or "").strip().lower()
    if not USERNAME_RE.match(username):
        return _response(
            400, {"error": "username is required: letters, digits, _ or - only"}
        )

    _put_link(user_id, "chesscom", username, verified=False)
    return _response(
        201,
        {
            "platform": "chesscom",
            "username": username,
            "verified": False,
            "note": "Chess.com OAuth is approval-gated; this link is unverified.",
        },
    )


# --- Listing ---------------------------------------------------------------


def list_links(event):
    user_id = _caller_sub(event)
    if not user_id:
        return _response(401, {"error": "unauthenticated"})

    # One query on the caller's partition, SK prefix LINK# - which is why links
    # are one item each rather than a map on a profile item.
    items = table.query(
        KeyConditionExpression="PK = :pk AND begins_with(SK, :prefix)",
        ExpressionAttributeValues={":pk": f"USER#{user_id}", ":prefix": "LINK#"},
    ).get("Items", [])

    return _response(
        200,
        {
            "links": [
                {
                    "platform": i["platform"],
                    "username": i["username"],
                    "verified": bool(i["verified"]),
                    "linkedAt": int(i["linkedAt"]),
                }
                for i in items
            ]
        },
    )


ROUTES = {
    "POST /link/lichess": start_lichess,
    "GET /link/lichess/callback": callback_lichess,
    "POST /link/chesscom": link_chesscom,
    "GET /links": list_links,
}


def handler(event, context):
    route = event.get("routeKey", "")
    fn = ROUTES.get(route)
    if not fn:
        return _response(404, {"error": "no such route"})
    return fn(event)
