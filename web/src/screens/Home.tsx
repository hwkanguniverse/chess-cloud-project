/**
 * Home: submit a player.
 *
 * The one screen behind <Authenticator>, because POST /games is the one route
 * behind the JWT authorizer. Amplify UI renders sign-in, sign-up, email
 * confirmation and password reset from that single element.
 */
import { useState, type FormEvent } from "react";
import { Authenticator } from "@aws-amplify/ui-react";
import { useNavigate } from "react-router-dom";

import { ApiError, submitPlayer, type SubmitResponse } from "../api";
import { Button, Card, Input } from "../components/ui";

// Matches USERNAME_RE in submit.py. Checked here purely so an obvious typo is
// caught without a round trip - the server validates regardless, and this
// copy is a convenience rather than a control.
const USERNAME_RE = /^[a-zA-Z0-9_-]{1,50}$/;

function SubmitForm() {
  const [username, setUsername] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<SubmitResponse | null>(null);
  const navigate = useNavigate();

  async function onSubmit(event: FormEvent) {
    event.preventDefault();
    const name = username.trim().toLowerCase();

    if (!USERNAME_RE.test(name)) {
      setError("Letters, digits, _ or - only.");
      return;
    }

    setBusy(true);
    setError(null);
    setResult(null);

    try {
      const response = await submitPlayer(name);
      setResult(response);
      // Straight to the player page: a first submit queues ~150 archives and
      // that page is where they visibly land. Delayed briefly so the counts
      // are readable rather than flashing past.
      setTimeout(() => navigate(`/player/chesscom/${name}`), 1200);
    } catch (err) {
      setError(
        err instanceof ApiError
          ? err.status === 404
            ? `No such player on Chess.com: ${name}`
            : err.status === 403
              ? "Confirm your email address before submitting - check your inbox for the code Cognito sent when you signed up."
              : err.message
          : "Could not reach the API.",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <Card padding={32} style={{ maxWidth: "34rem", margin: "0 auto" }}>
      <h1>Analyse a player</h1>
      <p className="muted">
        Every game Chess.com has for them, counted. Results, colours, time
        controls and rating range — across their whole history.
      </p>

      <form onSubmit={onSubmit} className="submit-form">
        <label htmlFor="username" className="sr-only">
          Chess.com username
        </label>
        <Input
          id="username"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          placeholder="chess.com username"
          autoComplete="off"
          autoCapitalize="none"
          spellCheck={false}
          disabled={busy}
        />
        <Button type="submit" disabled={busy || !username.trim()}>
          {busy ? "Submitting…" : "Analyse"}
        </Button>
      </form>

      {error && <p className="error small">{error}</p>}

      {result && (
        <p className="notice">
          {result.archives} archives found · {result.queued} queued ·{" "}
          {result.skipped} already done
          {result.refreshed && " · refreshing the latest"}
        </p>
      )}

      <p className="muted small" style={{ marginBottom: 0 }}>
        Chess.com only. Lichess is linkable as an account but has no archive
        list to walk, so it cannot be ingested this way.
      </p>
    </Card>
  );
}

export default function Home() {
  return (
    <Authenticator signUpAttributes={["email"]}>
      {() => <SubmitForm />}
    </Authenticator>
  );
}
