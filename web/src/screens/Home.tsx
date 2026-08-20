/**
 * Home: submit a player.
 *
 * The one screen behind <Authenticator>, because POST /games is the one route
 * behind the JWT authorizer. Amplify UI renders sign-in, sign-up, email
 * confirmation and password reset from that single element - the same five
 * screens the Cognito hosted UI was originally there to avoid hand-building.
 */
import { useState, type FormEvent } from "react";
import { Authenticator } from "@aws-amplify/ui-react";
import { useNavigate } from "react-router-dom";

import { ApiError, submitPlayer, type SubmitResponse } from "../api";

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
      // Straight to the player page: a first submit queues ~150 months and the
      // page is where they visibly land. Delayed briefly so the counts above
      // are readable rather than flashing past.
      setTimeout(() => navigate(`/player/chesscom/${name}`), 1200);
    } catch (err) {
      setError(
        err instanceof ApiError
          ? err.status === 404
            ? `No such player on Chess.com: ${name}`
            : err.message
          : "Could not reach the API.",
      );
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="card">
      <h1>Analyse a player</h1>
      <p className="muted">
        Every monthly archive Chess.com has for them, counted. Games, results,
        colours, time controls and rating range - month by month.
      </p>

      <form onSubmit={onSubmit} className="submit-form">
        <label htmlFor="username" className="sr-only">
          Chess.com username
        </label>
        <input
          id="username"
          value={username}
          onChange={(e) => setUsername(e.target.value)}
          placeholder="chess.com username"
          autoComplete="off"
          autoCapitalize="none"
          spellCheck={false}
          disabled={busy}
        />
        <button type="submit" disabled={busy || !username.trim()}>
          {busy ? "Submitting…" : "Analyse"}
        </button>
      </form>

      {error && <p className="error">{error}</p>}

      {result && (
        <p className="notice">
          {result.archives} archives found · {result.queued} queued ·{" "}
          {result.skipped} already done
          {result.refreshed && " · refreshing the live month"}
        </p>
      )}

      <p className="muted small">
        Chess.com only. Lichess is linkable as an account but has no archive
        list to walk, so it cannot be ingested this way.
      </p>
    </section>
  );
}

export default function Home() {
  return (
    <Authenticator signUpAttributes={["email"]}>
      {() => <SubmitForm />}
    </Authenticator>
  );
}
