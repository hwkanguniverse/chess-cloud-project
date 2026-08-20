/**
 * Player: cumulative totals, and every month with its own status.
 *
 * This is the screen submit points at, and the only one that polls. A first
 * submit fans out into ~150 months that arrive one at a time over a few
 * minutes, so the page has to show progress rather than wait for it - which is
 * exactly what the API's per-month statuses were shaped for.
 *
 * Polling stops when `pending` reaches zero. That matters: the alternative -
 * a fixed interval that runs forever - would have every open tab calling a
 * DynamoDB Query every few seconds indefinitely, which is the kind of thing
 * the stage throttle exists to catch and the bill exists to remind you of.
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";

import { ApiError, getPlayer, type Month, type PlayerResponse } from "../api";

// Slow enough that a 152-month ingest costs ~36 polls rather than ~90, fast
// enough that months visibly appear. The read is a paginated Query over the
// player's partition, so it is cheap but not free.
const POLL_MS = 5000;

function StatusPill({ month }: { month: Month }) {
  const label = month.status.toLowerCase();
  return (
    <span className={`pill pill-${label}`} title={month.error ?? undefined}>
      {label}
    </span>
  );
}

export default function Player() {
  const { platform = "", username = "" } = useParams();
  const [data, setData] = useState<PlayerResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notFound, setNotFound] = useState(false);

  // Held in a ref so the polling effect does not restart on every response -
  // depending on `data` would tear down and recreate the timer each tick.
  const pending = useRef(0);

  const load = useCallback(async () => {
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
      // or a blip should not permanently freeze a page mid-ingest.
      return pending.current;
    }
  }, [platform, username]);

  useEffect(() => {
    let cancelled = false;
    let timer: number | undefined;

    async function tick() {
      const remaining = await load();
      if (cancelled) return;
      if (remaining > 0) {
        timer = window.setTimeout(tick, POLL_MS);
      }
    }

    tick();

    return () => {
      cancelled = true;
      if (timer) window.clearTimeout(timer);
    };
  }, [load]);

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
  const done = months.length - data.pending;

  return (
    <section>
      <h1>{username}</h1>
      <p className="muted">
        {platform} ·{" "}
        {data.pending > 0 ? (
          <span className="pending">
            {done}/{months.length} months analysed — still working
          </span>
        ) : (
          `${months.length} months`
        )}
      </p>

      {error && <p className="notice warn">{error} — retrying</p>}

      <div className="stats">
        <Stat label="Games" value={totals.games.toLocaleString()} />
        <Stat
          label="Record"
          value={`${totals.wins}/${totals.draws}/${totals.losses}`}
          hint="W/D/L"
        />
        <Stat
          label="Win rate"
          value={totals.winRate != null ? `${totals.winRate}%` : "—"}
        />
        <Stat
          label="Rating"
          value={
            totals.ratingMin && totals.ratingMax
              ? `${totals.ratingMin}–${totals.ratingMax}`
              : "—"
          }
        />
        <Stat
          label="White / Black"
          value={`${totals.asWhite} / ${totals.asBlack}`}
        />
      </div>

      {Object.keys(totals.byClass ?? {}).length > 0 && (
        <p className="muted small">
          {Object.entries(totals.byClass)
            .sort((a, b) => b[1] - a[1])
            .map(([name, count]) => `${name} ${count.toLocaleString()}`)
            .join(" · ")}
        </p>
      )}

      <table className="table">
        <thead>
          <tr>
            <th>Month</th>
            <th></th>
            <th className="num">Games</th>
            <th className="num">W/D/L</th>
            <th className="num">Rating</th>
          </tr>
        </thead>
        <tbody>
          {months.map((month) => (
            <tr key={month.archive}>
              <td>
                {month.status === "COMPLETE" ? (
                  <Link
                    to={`/player/${platform}/${username}/${month.archive}`}
                  >
                    {month.archive}
                  </Link>
                ) : (
                  month.archive
                )}
              </td>
              <td>
                <StatusPill month={month} />
              </td>
              <td className="num">{month.summary?.games ?? "—"}</td>
              <td className="num">
                {month.summary
                  ? `${month.summary.wins}/${month.summary.draws}/${month.summary.losses}`
                  : "—"}
              </td>
              <td className="num">
                {month.summary?.ratingMin && month.summary?.ratingMax
                  ? `${month.summary.ratingMin}–${month.summary.ratingMax}`
                  : "—"}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}

function Stat({
  label,
  value,
  hint,
}: {
  label: string;
  value: string;
  hint?: string;
}) {
  return (
    <div className="stat">
      <div className="stat-value">{value}</div>
      <div className="stat-label">
        {label}
        {hint && <span className="muted"> ({hint})</span>}
      </div>
    </div>
  );
}
