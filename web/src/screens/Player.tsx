/**
 * Player: headline stats for one player, and the way in to their games.
 *
 * Months are deliberately absent from the UI. They are how Chess.com serves
 * data and how the worker stores it - a player thinks in games, not archives,
 * so the archive stays behind the network boundary.
 *
 * This screen is the one that watches an ingest happen: it polls while
 * archives are still landing, so a first submit is legible as 152 months fill
 * in. Totals are over COMPLETE months only, so they climb rather than
 * appearing all at once. The games themselves live on their own route (see
 * Games.tsx) - split out so the list has a URL, which also keeps the polling
 * here away from the pagination there.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";

import { ApiError, getPlayer, type PlayerResponse } from "../api";
import { ProgressBar, Stat } from "../components/ui";

const POLL_MS = 5000;

export default function Player() {
  const { platform = "", username = "" } = useParams();

  const [data, setData] = useState<PlayerResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notFound, setNotFound] = useState(false);

  // Last known pending count, so a failed poll can keep the loop alive at the
  // same cadence rather than reading it back off state that did not update.
  const pending = useRef(0);

  const loadPlayer = useCallback(async () => {
    try {
      const response = await getPlayer(platform, username);
      setData(response);
      pending.current = response.pending;
      setError(null);
      return response.pending;
    } catch (err) {
      if (err instanceof ApiError && err.status === 404) {
        setNotFound(true);
        return 0;
      }
      setError(err instanceof Error ? err.message : String(err));
      // Keep polling through a transient error: a 429 from the stage throttle
      // should not permanently freeze a page mid-ingest.
      return pending.current;
    }
  }, [platform, username]);

  // Poll while archives are still arriving. This is what makes a first submit
  // legible: 152 archives land one at a time over a few minutes.
  useEffect(() => {
    let cancelled = false;
    let timer: number | undefined;

    async function tick() {
      const remaining = await loadPlayer();
      if (cancelled) return;
      if (remaining > 0) timer = window.setTimeout(tick, POLL_MS);
    }

    tick();
    return () => {
      cancelled = true;
      if (timer) window.clearTimeout(timer);
    };
  }, [loadPlayer]);

  if (notFound) {
    return (
      <p className="empty">
        Not analysed yet. <Link to="/">Submit {username}</Link> to start.
      </p>
    );
  }

  if (error && !data) return <p className="error">{error}</p>;
  if (!data) return <p className="empty">Loading…</p>;

  const { totals, months } = data;
  const complete = months.filter((m) => m.status === "COMPLETE").length;
  const failed = months.filter((m) => m.status === "FAILED").length;
  const percent = Math.round((complete / Math.max(months.length, 1)) * 100);

  return (
    <section>
      <h1>{username}</h1>
      <p className="muted">{platform}</p>

      {data.pending > 0 && (
        <div className="progress-row">
          <span className="label">Reading history</span>
          <span className="bar">
            <ProgressBar value={percent} height={8} />
          </span>
          <span className="muted small">{percent}%</span>
        </div>
      )}

      {error && <p className="notice warn">{error} — retrying</p>}

      <div className="stats">
        <Stat label="Games" value={totals.games.toLocaleString()} />
        <Stat
          label="Won"
          value={totals.wins.toLocaleString()}
          tone="win"
          sub={
            totals.winRate != null ? `${totals.winRate}% win rate` : undefined
          }
        />
        <Stat label="Drawn" value={totals.draws.toLocaleString()} />
        <Stat label="Lost" value={totals.losses.toLocaleString()} tone="loss" />
        <Stat
          label="Rating"
          value={
            totals.ratingMin && totals.ratingMax
              ? `${totals.ratingMin}–${totals.ratingMax}`
              : "—"
          }
          // Two lines rather than one wrapping string: at six figures the
          // single line broke mid-phrase ("64,817 as white ·" / "64,574 as
          // black"), which read as damage rather than as two facts.
          sub={
            <>
              {totals.asWhite.toLocaleString()} as white
              <br />
              {totals.asBlack.toLocaleString()} as black
            </>
          }
        />
      </div>

      {Object.keys(totals.byClass ?? {}).length > 0 && (
        <div className="breakdown">
          <span className="label">By time control</span>
          <span className="muted small">
            {Object.entries(totals.byClass)
              .sort((a, b) => b[1] - a[1])
              .map(([name, count]) => `${name} ${count.toLocaleString()}`)
              .join(" · ")}
          </span>
        </div>
      )}

      {failed > 0 && (
        <p className="notice warn">
          Chess.com could not return {failed}{" "}
          {failed === 1 ? "archive" : "archives"}, so some games are missing.
        </p>
      )}

      <p className="games-link">
        <Link to={`/player/${platform}/${username}/games`}>
          View all {totals.games.toLocaleString()} games &rarr;
        </Link>
      </p>

    </section>
  );
}
