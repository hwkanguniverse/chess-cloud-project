/**
 * Month: one archive, with its games.
 *
 * The drill-down. The player screen deliberately never carries games - 152
 * months of them is tens of megabytes - so this is the only place the summary
 * rows are fetched, one month at a time.
 *
 * A row links back to Chess.com rather than showing moves: the stored row has
 * no moves in it, by design. That was the storage decision that kept an
 * 828-game month inside a single 400KB DynamoDB item.
 */
import { useEffect, useState } from "react";
import { Link, useParams } from "react-router-dom";

import { getMonth, outcomeOf, type MonthDetail } from "../api";

function when(seconds: number): string {
  return new Date(seconds * 1000).toLocaleDateString(undefined, {
    day: "numeric",
    month: "short",
  });
}

export default function MonthScreen() {
  const { platform = "", username = "", archive = "" } = useParams();
  const [data, setData] = useState<MonthDetail | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    getMonth(platform, username, archive)
      .then((response) => !cancelled && setData(response))
      .catch((err) => !cancelled && setError(String(err.message ?? err)));

    return () => {
      cancelled = true;
    };
  }, [platform, username, archive]);

  if (error) return <p className="error">{error}</p>;
  if (!data) return <p className="empty">Loading…</p>;

  // Newest first. The worker stores them in Chess.com's order, which is
  // oldest first - sorting here rather than there keeps the stored row as
  // small as it is and costs nothing at these sizes.
  const games = [...(data.games ?? [])].sort((a, b) => b.end - a.end);

  return (
    <section>
      <p className="crumb">
        <Link to={`/player/${platform}/${username}`}>← {username}</Link>
      </p>
      <h1>{archive}</h1>

      {data.status !== "COMPLETE" && (
        <p className="notice warn">
          {data.status}
          {data.error && ` — ${data.error}`}
        </p>
      )}

      {data.summary && (
        <p className="muted">
          {data.summary.games} games ·{" "}
          {data.summary.wins}/{data.summary.draws}/{data.summary.losses} W/D/L
          {data.summary.ratingMin && data.summary.ratingMax && (
            <> · rating {data.summary.ratingMin}–{data.summary.ratingMax}</>
          )}
        </p>
      )}

      {games.length === 0 ? (
        <p className="empty">No games this month.</p>
      ) : (
        <table className="table">
          <thead>
            <tr>
              <th>Date</th>
              <th></th>
              <th>Opponent</th>
              <th className="num">Rating</th>
              <th>Result</th>
              <th>Time</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {games.map((game) => {
              const outcome = outcomeOf(game.result);
              return (
                <tr key={game.url}>
                  <td className="muted">{when(game.end)}</td>
                  <td>
                    <span
                      className={`disc disc-${game.colour}`}
                      title={game.colour === "w" ? "White" : "Black"}
                      aria-label={game.colour === "w" ? "White" : "Black"}
                    />
                  </td>
                  <td>{game.opp}</td>
                  <td className="num muted">{game.oppRating}</td>
                  <td>
                    <span className={`outcome outcome-${outcome}`}>
                      {outcome}
                    </span>
                    <span className="muted small"> {game.result}</span>
                  </td>
                  <td className="muted">{game.class}</td>
                  <td>
                    <a href={game.url} target="_blank" rel="noreferrer">
                      view
                    </a>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </section>
  );
}
