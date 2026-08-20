/**
 * Directory: every player anyone has submitted.
 *
 * Public, like the API route behind it. This is the screen that makes the
 * app's "analysis is public shared data" decision visible - the other read
 * screens require you to already know a username, this one hands out the list.
 */
import { useEffect, useState } from "react";
import { Link } from "react-router-dom";

import { listPlayers, type DirectoryEntry } from "../api";

function ago(seconds: number | null): string {
  if (!seconds) return "—";
  const delta = Date.now() / 1000 - seconds;
  if (delta < 60) return "just now";
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
  return `${Math.floor(delta / 86400)}d ago`;
}

export default function Directory() {
  const [players, setPlayers] = useState<DirectoryEntry[] | null>(null);
  const [truncated, setTruncated] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    listPlayers()
      .then((response) => {
        if (cancelled) return;
        setPlayers(response.players);
        setTruncated(response.truncated);
      })
      .catch((err) => !cancelled && setError(String(err.message ?? err)));

    // StrictMode mounts effects twice in development. Without this the second
    // response can land after the first and overwrite fresher state - harmless
    // here, but the same pattern matters on the polling screen.
    return () => {
      cancelled = true;
    };
  }, []);

  if (error) return <p className="error">{error}</p>;
  if (!players) return <p className="empty">Loading…</p>;
  if (players.length === 0) {
    return <p className="empty">Nobody has been analysed yet.</p>;
  }

  return (
    <section>
      <h1>Players</h1>

      {truncated && (
        <p className="notice warn">
          This list is incomplete — the directory reads the whole table and hit
          its page limit.
        </p>
      )}

      <table className="table">
        <thead>
          <tr>
            <th>Player</th>
            <th className="num">Games</th>
            <th></th>
            <th className="num">Analysed</th>
          </tr>
        </thead>
        <tbody>
          {players.map((player) => (
            <tr key={`${player.platform}/${player.username}`}>
              <td>
                <Link to={`/player/${player.platform}/${player.username}`}>
                  {player.username}
                </Link>
              </td>
              <td className="num">{player.games.toLocaleString()}</td>
              {/* Progress as a share of the work, not a month count - the
                  archive is the worker's unit and stays out of the product. */}
              <td>
                {player.pending > 0 && (
                  <span className="pending small">
                    ingesting —{" "}
                    {Math.round(
                      (player.complete / Math.max(player.months, 1)) * 100,
                    )}
                    %
                  </span>
                )}
              </td>
              <td className="num muted">{ago(player.lastAnalysedAt)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
