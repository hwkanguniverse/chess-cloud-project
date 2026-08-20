/**
 * Player: the whole screen. Headline stats, then every game as one list.
 *
 * Months are deliberately absent from the UI. They are how Chess.com serves
 * data and how the worker stores it - a player thinks in games, not archives,
 * so the archive stays behind the network boundary. What the user sees is a
 * continuous list, newest first, that loads more as they scroll.
 *
 * The month survives as the *fetch* unit: games live one item per archive, so
 * "load more" means "fetch the next archive". That is why this screen holds a
 * cursor into the month list rather than an offset into the games.
 *
 * Two independent loading concerns share this screen, and keeping them
 * separate is what makes it behave during a first ingest:
 *
 *   - the month list, which is polled while months are still landing
 *   - the games, which are fetched on demand and never re-fetched
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useParams } from "react-router-dom";

import {
  ApiError,
  getMonth,
  getPlayer,
  outcomeOf,
  type Game,
  type PlayerResponse,
} from "../api";

const POLL_MS = 5000;

// Load in games, not archives. Games per archive varies by two orders of
// magnitude between players - measured against live data, erik averages ~23
// games in a recent month and danielnaroditsky ~1,900 - so any fixed archive
// count is simultaneously too few for one and far too many for the other.
// Asking for a number of games instead makes a page of the list mean the same
// thing for a casual player and a streamer.
const GAMES_PER_PAGE = 200;

// Ceiling on how many archives one page will walk to reach that. A quiet
// player can have months with almost nothing in them; without this, filling a
// page could mean twenty sequential requests.
const MAX_ARCHIVES_PER_PAGE = 6;

/** A game plus nothing else: the archive it came from is not carried forward. */
type LoadedGame = Game;

function gameDate(seconds: number): string {
  return new Date(seconds * 1000).toLocaleDateString(undefined, {
    day: "numeric",
    month: "short",
    year: "numeric",
  });
}

export default function Player() {
  const { platform = "", username = "" } = useParams();

  const [data, setData] = useState<PlayerResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notFound, setNotFound] = useState(false);

  const [games, setGames] = useState<LoadedGame[]>([]);
  const [loadingGames, setLoadingGames] = useState(false);
  const [gamesError, setGamesError] = useState<string | null>(null);

  // How far into the COMPLETE months we have fetched. The months array is
  // newest-first, so this walks backwards through the player's history.
  const cursor = useRef(0);
  const pending = useRef(0);
  // Archives already fetched. Polling reorders nothing, but a month completing
  // mid-scroll could otherwise be pulled twice.
  const fetched = useRef(new Set<string>());

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
      return pending.current;
    }
  }, [platform, username]);

  // Poll the month list while months are still arriving. This is what makes a
  // first submit legible: 152 months land one at a time over a few minutes.
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

  /**
   * Walk archives newest-first until roughly GAMES_PER_PAGE games are in hand.
   *
   * Sequential rather than parallel, and that is deliberate twice over: the
   * archives are appended in order, and firing several requests at once to
   * render rows nobody has scrolled to is throughput the stage throttle would
   * rather not spend.
   *
   * A page overshoots rather than truncates. One archive is one item and one
   * request, so stopping at exactly 200 games would mean holding the rest of
   * that archive somewhere and remembering to serve it before the next
   * request. Appending the whole archive costs nothing and keeps the cursor a
   * single number.
   */
  const loadMore = useCallback(async () => {
    if (!data || loadingGames) return;

    const complete = data.months.filter((m) => m.status === "COMPLETE");
    if (cursor.current >= complete.length) return;

    setLoadingGames(true);
    setGamesError(null);

    try {
      let added = 0;
      let requests = 0;

      while (
        cursor.current < complete.length &&
        added < GAMES_PER_PAGE &&
        requests < MAX_ARCHIVES_PER_PAGE
      ) {
        const month = complete[cursor.current];
        cursor.current += 1;

        if (fetched.current.has(month.archive)) continue;
        fetched.current.add(month.archive);
        requests += 1;

        const detail = await getMonth(platform, username, month.archive);
        const batch = detail.games ?? [];
        if (batch.length === 0) continue;

        // Sort within the batch only. Archives arrive newest-first and each
        // one is internally oldest-first, so sorting the batch before
        // appending keeps the whole list ordered without ever re-sorting
        // thousands of already-rendered rows. Verified live: two archives
        // walked this way concatenate to a correctly descending list.
        batch.sort((a, b) => b.end - a.end);
        added += batch.length;
        setGames((current) => [...current, ...batch]);
      }
    } catch (err) {
      setGamesError(err instanceof Error ? err.message : String(err));
    } finally {
      setLoadingGames(false);
    }
  }, [data, loadingGames, platform, username]);

  // First paint: fill one page. Runs once the month list exists, and not
  // again - the guard is the cursor, not the effect deps.
  useEffect(() => {
    if (data && cursor.current === 0) void loadMore();
  }, [data, loadMore]);

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
  const more = cursor.current < complete;

  return (
    <section>
      <h1>{username}</h1>
      <p className="muted">
        {platform}
        {data.pending > 0 && (
          <>
            {" · "}
            <span className="pending">
              still ingesting — {complete} of {months.length} archives read
            </span>
          </>
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

      {failed > 0 && (
        <p className="notice warn">
          {failed} {failed === 1 ? "archive" : "archives"} could not be read
          from Chess.com, so some games are missing.
        </p>
      )}

      <GamesTable games={games} />

      <div className="load-more">
        {gamesError && <p className="error">{gamesError}</p>}
        {loadingGames && <p className="muted">Loading games…</p>}
        {!loadingGames && more && (
          <button type="button" onClick={() => void loadMore()}>
            Load more
          </button>
        )}
        {!loadingGames && !more && games.length > 0 && (
          <p className="muted small">
            {games.length.toLocaleString()} games — that is all of them.
          </p>
        )}
        {!loadingGames && !more && games.length === 0 && data.pending > 0 && (
          <p className="muted">Waiting for the first archive…</p>
        )}
      </div>
    </section>
  );
}

function GamesTable({ games }: { games: LoadedGame[] }) {
  if (games.length === 0) return null;

  return (
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
              <td className="muted">{gameDate(game.end)}</td>
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
                <span className={`outcome outcome-${outcome}`}>{outcome}</span>
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
