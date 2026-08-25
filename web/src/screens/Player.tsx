/**
 * Player: the whole screen. Headline stats, then every game as one list.
 *
 * Months are deliberately absent from the UI. They are how Chess.com serves
 * data and how the worker stores it - a player thinks in games, not archives,
 * so the archive stays behind the network boundary. What the user sees is a
 * continuous list, newest first, that loads more on demand.
 *
 * The archive survives as the *fetch* unit, because that is a storage fact:
 * games live one item per archive, which is what keeps an 828-game month
 * inside a 400KB item. So "load more" walks archives newest-first. The user
 * never sees one; the network tab does.
 *
 * Two independent loading concerns share this screen, and keeping them
 * separate is what makes it behave during a first ingest:
 *
 *   - the archive list, polled while archives are still landing
 *   - the games, fetched on demand and never re-fetched
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
import { Button, ProgressBar, ResultPill, Stat } from "../components/ui";

const POLL_MS = 5000;

// Load in games, not archives. Games per archive varies by two orders of
// magnitude between players - measured against live data, erik averages ~23
// games in a recent month and danielnaroditsky ~1,900 - so any fixed archive
// count is simultaneously too few for one and far too many for the other.
// Asking for a number of games instead makes a page of the list mean the same
// thing for a casual player and a streamer.
const GAMES_PER_PAGE = 200;

// Ceiling on how many archives one page will walk to reach that. A quiet
// player can have archives with almost nothing in them; without this, filling
// a page could mean twenty sequential requests.
const MAX_ARCHIVES_PER_PAGE = 6;

function gameDate(seconds: number): string {
  return new Date(seconds * 1000).toLocaleDateString(undefined, {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

export default function Player() {
  const { platform = "", username = "" } = useParams();

  const [data, setData] = useState<PlayerResponse | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [notFound, setNotFound] = useState(false);

  const [games, setGames] = useState<Game[]>([]);
  const [loadingGames, setLoadingGames] = useState(false);
  const [gamesError, setGamesError] = useState<string | null>(null);

  // How far into the COMPLETE archives we have fetched. The list is
  // newest-first, so this walks backwards through the player's history.
  const cursor = useRef(0);
  const pending = useRef(0);
  // Archives already fetched. Polling reorders nothing, but an archive
  // completing mid-scroll could otherwise be pulled twice.
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

  // First paint: fill one page. Runs once the archive list exists, and not
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
          sub={`${totals.asWhite.toLocaleString()} as white · ${totals.asBlack.toLocaleString()} as black`}
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
          Chess.com could not return {failed}{" "}
          {failed === 1 ? "archive" : "archives"}, so some games are missing.
        </p>
      )}

      <GamesTable games={games} />

      <div className="load-more">
        {gamesError && <p className="error small">{gamesError}</p>}
        {loadingGames && <p className="muted small">Loading games…</p>}
        {!loadingGames && more && (
          <Button variant="secondary" onClick={() => void loadMore()}>
            Load more
          </Button>
        )}
        {!loadingGames && !more && games.length > 0 && (
          <p className="muted small">
            {games.length.toLocaleString()} games — that is all of them.
          </p>
        )}
        {!loadingGames && !more && games.length === 0 && data.pending > 0 && (
          <p className="muted small">Waiting for the first archive…</p>
        )}
      </div>
    </section>
  );
}

function GamesTable({ games }: { games: Game[] }) {
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
          <th></th>
          <th>Time</th>
          <th></th>
        </tr>
      </thead>
      <tbody>
        {games.map((game) => (
          <tr key={game.url}>
            <td className="mono muted">{gameDate(game.end)}</td>
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
              <ResultPill result={outcomeOf(game.result)} size="sm" />
            </td>
            {/* Chess.com's own word for how it ended - "resigned", "timeout",
                "checkmated". The pill says who won; this says how. */}
            <td className="muted small">{game.result}</td>
            <td className="muted small">{game.class}</td>
            <td>
              <a href={game.url} target="_blank" rel="noreferrer">
                view
              </a>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
