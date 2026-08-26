/**
 * Games: every game a player has, newest first.
 *
 * Split from the player screen so the list has a URL. What that URL names is
 * the *list*, not a position in it - /player/chesscom/erik/games always opens
 * at the newest page, and "load more" stays in-page state. A shared link
 * means "erik's games", never "erik's games scrolled to March 2019".
 *
 * That is a deliberate limit rather than an oversight. Naming a position
 * would mean either a page number, which is unstable because a month
 * completing mid-ingest shifts what page three contains, or an archive, which
 * would put months back in front of the user - the one thing this list exists
 * to keep out of the product. Neither is worth it to deep-link a scroll
 * position nobody has asked to share.
 *
 * Months survive as the *fetch* unit, because that is a storage fact: games
 * live one item per archive, which is what keeps an 828-game month inside a
 * 400KB item. So "load more" walks archives newest-first. The user never sees
 * one; the network tab does.
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
import { Button, ResultPill } from "../components/ui";

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

export default function Games() {
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
  // Archives already fetched, guarding against pulling one twice.
  const fetched = useRef(new Set<string>());

  // The archive list, fetched once. This screen does not poll: it is opened
  // to read games that already exist, and a list that grew under a reader
  // mid-scroll would be worse than one that is briefly stale. The player
  // screen is where an ingest in progress is watched.
  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const response = await getPlayer(platform, username);
        if (!cancelled) setData(response);
      } catch (err) {
        if (cancelled) return;
        if (err instanceof ApiError && err.status === 404) setNotFound(true);
        else setError(err instanceof Error ? err.message : String(err));
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [platform, username]);

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
  if (!data) return <p className="empty">Loading&hellip;</p>;

  const complete = data.months.filter((m) => m.status === "COMPLETE").length;
  const more = cursor.current < complete;

  return (
    <section>
      <p className="muted small">
        <Link to={`/player/${platform}/${username}`}>&larr; {username}</Link>
      </p>
      <h1>Games</h1>
      <p className="muted">
        {data.totals.games.toLocaleString()} games
        {data.pending > 0 && ` · ${data.pending} months still loading`}
      </p>

      <GamesTable games={games} />

      <div className="load-more">
        {gamesError && <p className="error small">{gamesError}</p>}
        {loadingGames && <p className="muted small">Loading games&hellip;</p>}
        {!loadingGames && more && (
          <Button variant="secondary" onClick={() => void loadMore()}>
            Load more
          </Button>
        )}
        {!loadingGames && !more && games.length > 0 && (
          <p className="muted small">
            {games.length.toLocaleString()} games &mdash; that is all of them.
          </p>
        )}
        {!loadingGames && !more && games.length === 0 && data.pending > 0 && (
          <p className="muted small">Waiting for the first archive&hellip;</p>
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
