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
  analysePlayer,
  getMonth,
  getPlayer,
  outcomeOf,
  type EvaluationState,
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

  // The analyse request itself, kept apart from the evaluation *state* the
  // player route reports. One is "did my click succeed", the other is "how far
  // along is the engine" - conflating them makes a finished run look like a
  // stuck button.
  const [analysing, setAnalysing] = useState(false);
  const [analyseNote, setAnalyseNote] = useState<string | null>(null);
  const [analyseError, setAnalyseError] = useState<string | null>(null);

  // How far into the COMPLETE archives we have fetched. The list is
  // newest-first, so this walks backwards through the player's history.
  const cursor = useRef(0);
  const pending = useRef(0);
  // Games queued for evaluation but not yet finished. Drives the poll the same
  // way `pending` does for ingestion.
  const outstanding = useRef(0);
  // Archives already fetched. Polling reorders nothing, but an archive
  // completing mid-scroll could otherwise be pulled twice.
  const fetched = useRef(new Set<string>());

  const loadPlayer = useCallback(async () => {
    try {
      const response = await getPlayer(platform, username);
      setData(response);
      pending.current = response.pending;
      outstanding.current = response.evaluation?.outstanding ?? 0;
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
      // Keep polling while EITHER ingestion or evaluation is still going. The
      // two are independent - a player can be fully ingested and mid-analysis
      // - so the poll has to outlive whichever finishes first.
      if (remaining > 0 || outstanding.current > 0) {
        timer = window.setTimeout(tick, POLL_MS);
      }
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

  const requestAnalysis = useCallback(async () => {
    setAnalysing(true);
    setAnalyseError(null);
    setAnalyseNote(null);
    try {
      const result = await analysePlayer(username, platform);

      if (result.alreadyQueued) {
        // Not an error. Somebody - possibly this user in another tab - already
        // started this player, and the request cost no rate-limit token.
        setAnalyseNote(
          `Already being analysed: ${result.alreadyQueued.toLocaleString()} games in progress.`,
        );
      } else if (result.queued > 0) {
        setAnalyseNote(`Queued ${result.queued.toLocaleString()} games.`);
        // Start the poll immediately rather than waiting for the next tick, so
        // the progress bar appears on click rather than five seconds later.
        outstanding.current = result.queued;
        void loadPlayer();
      } else {
        setAnalyseNote("Everything already evaluated - nothing to do.");
      }
    } catch (err) {
      if (err instanceof ApiError && err.status === 429) {
        // The bucket is per account and charged only for real work, so this
        // means the user has genuinely started five new players in an hour.
        const body = err.body as { retryAfter?: number } | undefined;
        const mins = Math.ceil((body?.retryAfter ?? 3600) / 60);
        setAnalyseError(
          `Analysis limit reached. Try again in about ${mins} ${mins === 1 ? "minute" : "minutes"}.`,
        );
      } else if (err instanceof ApiError && err.status === 401) {
        setAnalyseError("Sign in to analyse a player.");
      } else {
        setAnalyseError(err instanceof Error ? err.message : String(err));
      }
    } finally {
      setAnalysing(false);
    }
  }, [loadPlayer, platform, username]);

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
  // Still ingesting. FAILED months are not pending - a player with one archive
  // Chess.com will never serve would otherwise never show totals at all.
  const loading = data.pending > 0;

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

      {/* Totals are withheld until every month is in. They are only ever
          computed over COMPLETE months, so mid-ingest they are not a partial
          view of the answer - they are a different, smaller answer that looks
          exactly like the real one. A win rate over 3 of 230 months is a
          number someone will read and believe. The progress bar above is the
          loading state; these appear when they mean something. */}
      {loading ? (
        <p className="stats-pending muted">
          Reading {months.length.toLocaleString()} months of history&hellip;
          Totals appear once every month is in.
        </p>
      ) : (
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
      )}

      {!loading && Object.keys(totals.byClass ?? {}).length > 0 && (
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

      {/* The second statistics group. Everything above needs no engine and is
          shown to everyone; this appears only once games have been evaluated,
          which is the split the whole phase rests on. */}
      {!loading && (
        <Evaluation
          state={data.evaluation}
          games={games}
          busy={analysing}
          note={analyseNote}
          error={analyseError}
          onAnalyse={() => void requestAnalysis()}
        />
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

/**
 * Evaluation: the engine's half of the page.
 *
 * The standing decision is that the dashboard is the product and the
 * single-game report is not - Lichess does that better - so there is no
 * move-by-move eval curve for one game here. The phase chart below is the
 * other thing: an *aggregate across games*, which is what a dashboard is for.
 * It answers "how well does this player play, where do they go wrong, and
 * which games went worst", and stops there.
 *
 * `inScope` rather than the player's total game count is the denominator
 * everywhere here: evaluation is capped at 100 per time control and excludes
 * daily, so 201 of 1,502 games is complete, not 13%.
 */
function Evaluation({
  state,
  games,
  busy,
  note,
  error,
  onAnalyse,
}: {
  state?: EvaluationState;
  games: Game[];
  busy: boolean;
  note: string | null;
  error: string | null;
  onAnalyse: () => void;
}) {
  if (!state) return null;

  // Aggregated over the games in hand rather than fetched: the numbers are
  // per-game on rows the list already holds, so a separate call would be a
  // second source of truth for arithmetic the client can do.
  const rated = games.filter((g) => g.acpl != null && g.evalError == null);
  const summary =
    rated.length > 0
      ? {
          n: rated.length,
          acpl: rated.reduce((t, g) => t + (g.acpl ?? 0), 0) / rated.length,
          blunders: rated.reduce((t, g) => t + (g.blunders ?? 0), 0),
          mistakes: rated.reduce((t, g) => t + (g.mistakes ?? 0), 0),
          inaccuracies: rated.reduce((t, g) => t + (g.inaccuracies ?? 0), 0),
          // The five that went worst. This is the thing a player actually
          // wants from an aggregate: not "your average is 72.8" but "look at
          // these".
          worst: [...rated]
            .sort((a, b) => (b.acpl ?? 0) - (a.acpl ?? 0))
            .slice(0, 5),
        }
      : null;

  // Summed loss and move count per bucket across games, then divided - never
  // an average of per-game averages, which would weight a 12-move miniature
  // the same as a 90-move grind.
  //
  // Games evaluated before the phase fields existed simply have no phaseCount
  // and drop out, which is what let the backfill run as a background job
  // rather than a flag day.
  const phased = rated.filter((g) => g.phaseCount != null && g.phaseLoss != null);
  const phases =
    phased.length > 0
      ? (() => {
          const loss = new Array(10).fill(0);
          const count = new Array(10).fill(0);
          for (const g of phased) {
            g.phaseLoss?.forEach((v, i) => (loss[i] += v));
            g.phaseCount?.forEach((v, i) => (count[i] += v));
          }
          const means = loss.map((l, i) => (count[i] > 0 ? l / count[i] : null));
          return { means, count, games: phased.length };
        })()
      : null;

  const { evaluated, outstanding, inScope, excluded, depth } = state;
  const running = outstanding > 0;
  const done = inScope > 0 && outstanding === 0;
  const percent = inScope > 0 ? Math.round((evaluated / inScope) * 100) : 0;

  const excludedTotal = Object.values(excluded ?? {}).reduce((a, b) => a + b, 0);

  return (
    <section className="evaluation">
      <div className="evaluation-head">
        <h2>Engine analysis</h2>
        {done ? (
          <span className="muted small">
            {evaluated.toLocaleString()} games at depth {depth}
          </span>
        ) : (
          <Button variant="primary" onClick={onAnalyse} disabled={busy || running}>
            {busy
              ? "Requesting…"
              : running
                ? "Analysing…"
                : evaluated > 0
                  ? `Analyse ${outstanding.toLocaleString()} new games`
                  : `Analyse ${inScope.toLocaleString()} games`}
          </Button>
        )}
      </div>

      {error && <p className="notice warn">{error}</p>}
      {note && !error && <p className="muted small">{note}</p>}

      {/* The headline numbers, over the games actually loaded into the list.
          Stated as "of N loaded" rather than presented as the player's career
          average, because the list is paginated - claiming otherwise would be
          the same mistake as showing a win rate over 3 of 230 months. */}
      {summary && (
        <>
          <div className="stats">
            <Stat
              label="Avg centipawn loss"
              value={summary.acpl.toFixed(1)}
              sub={`over ${summary.n.toLocaleString()} evaluated ${summary.n === 1 ? "game" : "games"} loaded`}
            />
            <Stat
              label="Blunders"
              value={summary.blunders.toLocaleString()}
              tone="loss"
              sub={`${(summary.blunders / summary.n).toFixed(2)} per game`}
            />
            <Stat
              label="Mistakes"
              value={summary.mistakes.toLocaleString()}
              sub={`${(summary.mistakes / summary.n).toFixed(2)} per game`}
            />
            <Stat
              label="Inaccuracies"
              value={summary.inaccuracies.toLocaleString()}
              sub={`${(summary.inaccuracies / summary.n).toFixed(2)} per game`}
            />
          </div>

          {/* Not rendered mid-run: the curve would shift on every 5s poll,
              and a chart that moves while you read it reads as broken. The
              progress row below is the loading state. */}
          {phases && !running && (
            <PhaseChart
              means={phases.means}
              count={phases.count}
              games={phases.games}
            />
          )}

          {summary.worst.length > 0 && (
            <div className="worst">
              <span className="label">Worst games</span>
              <ul className="worst-list">
                {summary.worst.map((g) => (
                  <li key={g.url}>
                    <a href={g.url} target="_blank" rel="noreferrer">
                      vs {g.opp}
                    </a>
                    <span className="muted small">
                      {" "}
                      · {g.acpl?.toFixed(0)} cp avg loss
                      {g.blunders ? ` · ${g.blunders} blunders` : ""}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </>
      )}

      {running && (
        <div className="progress-row">
          <span className="label">Evaluating</span>
          <span className="bar">
            <ProgressBar value={percent} height={8} />
          </span>
          <span className="muted small">
            {evaluated.toLocaleString()} / {inScope.toLocaleString()}
          </span>
        </div>
      )}

      {/* Games that will never be evaluated are stated rather than left as an
          unexplained gap between the game count and the evaluated count. */}
      {excludedTotal > 0 && (
        <p className="muted small">
          {Object.entries(excluded)
            .map(([name, n]) => `${n.toLocaleString()} ${name}`)
            .join(", ")}{" "}
          not evaluated — an engine and a database are legal there, so
          centipawn loss would measure the tools rather than the player.
        </p>
      )}

      {inScope === 0 && (
        <p className="muted small">
          No games in scope for evaluation.
        </p>
      )}
    </section>
  );
}

/**
 * PhaseChart: average centipawn loss across the course of a game.
 *
 * The x axis is *percentage of the game*, not move number, and that choice is
 * what makes the chart honest. Measured over theohwk's 201 games: with fixed
 * move boundaries (opening <= 12, midgame <= 30) the midgame looked worst at
 * 92 cp - but 56% of games never reach move 31, so the endgame figure was
 * computed over fewer than half the games. By percentage every game
 * contributes to every bucket and the curve describes all of them.
 *
 * The phase labels are spaced evenly and deliberately claim no move number.
 * Where an opening ends is a judgement this code does not have to make, and
 * the reader can group the curve by eye.
 *
 * Inline SVG rather than a charting library: ten points do not justify a
 * dependency, and this is the only drawing in the app.
 */
function PhaseChart({
  means,
  count,
  games,
}: {
  means: (number | null)[];
  count: number[];
  games: number;
}) {
  const points = means
    .map((m, i) => ({ m, i }))
    .filter((p): p is { m: number; i: number } => p.m != null);
  if (points.length < 3) return null;

  // Geometry in an arbitrary viewBox, scaled by CSS. The axis starts at zero
  // because centipawn loss is a magnitude - a truncated axis would exaggerate
  // the rise, which is the whole thing the chart is claiming.
  const W = 320;
  const H = 96;

  // Round the top up to a clean number so the axis reads 0/50/100 rather than
  // 0/54.6/109.2. Ticks a reader cannot say out loud are not worth drawing.
  //
  // The step is chosen from the *rounded* top rather than the raw peak, and the
  // top is the next round number above the peak rather than above peak x 1.1.
  // Padding first and rounding second compounds: a peak of 94.9 became a top of
  // 125, squashing the curve into three-quarters of the plot for no reason.
  const peak = Math.max(...points.map((p) => p.m));
  const step = peak <= 40 ? 10 : peak <= 100 ? 25 : peak <= 200 ? 50 : 100;
  const top = Math.max(step, Math.ceil(peak / step) * step);
  const ticks: number[] = [];
  for (let v = 0; v <= top; v += step) ticks.push(v);

  const x = (i: number) => (i / (means.length - 1)) * W;
  const y = (m: number) => H - (m / top) * H;

  const line = points.map((p) => `${x(p.i)},${y(p.m)}`).join(" ");
  const area = `${x(points[0].i)},${H} ${line} ${x(points[points.length - 1].i)},${H}`;

  const worst = points.reduce((a, b) => (b.m > a.m ? b : a));

  return (
    <div className="phases">
      <div className="phase-head">
        <span className="label">Where the mistakes happen</span>
        {/* "Lower is better" earns its place: up meaning worse is the opposite
            of most charts a reader has seen, and nothing else on the page
            says so. */}
        <span className="muted small">
          avg centipawn loss per move · lower is better
        </span>
      </div>

      <div className="phase-plot">
        {/* Labels live in HTML, not in the SVG: preserveAspectRatio="none"
            stretches the viewBox horizontally to fill the column, which would
            smear any text drawn inside it. */}
        <div className="phase-y" aria-hidden="true">
          {[...ticks].reverse().map((v) => (
            <span key={v}>{v}</span>
          ))}
        </div>

        <svg
          className="phase-chart"
          viewBox={`0 0 ${W} ${H}`}
          preserveAspectRatio="none"
          role="img"
          aria-label={
            `Average centipawn loss per move across the game, on a scale of 0 ` +
            `to ${top}. Lower is better. Rises from ` +
            `${Math.round(points[0].m)} in the opening to a worst of ` +
            `${Math.round(worst.m)}.`
          }
        >
          {/* Gridlines at the labelled values, so a reader can measure the
              curve rather than only see its shape. The zero line doubles as
              the axis. */}
          {ticks.map((v) => (
            <line
              key={v}
              x1="0"
              x2={W}
              y1={y(v)}
              y2={y(v)}
              stroke={v === 0 ? "var(--border-strong)" : "var(--border)"}
              strokeWidth="1"
              vectorEffect="non-scaling-stroke"
            />
          ))}
          <polygon points={area} fill="var(--loss-soft)" />
          <polyline
            points={line}
            fill="none"
            stroke="var(--loss)"
            strokeWidth="2"
            strokeLinejoin="round"
            strokeLinecap="round"
            vectorEffect="non-scaling-stroke"
          />
          {/* The single worst bucket, marked - the chart's one claim. */}
          <circle cx={x(worst.i)} cy={y(worst.m)} r="3" fill="var(--loss)"
            vectorEffect="non-scaling-stroke" />
        </svg>
      </div>

      {/* Hover gives the number and how many moves it rests on, so a point
          computed from a handful of moves is not read as confidently as one
          from hundreds. */}
      <div className="phase-ticks" aria-hidden="true">
        {means.map((m, i) => (
          <span
            key={i}
            title={
              m == null
                ? "no moves in this part of the game"
                : `${Math.round(m)} cp average loss, over ${count[i].toLocaleString()} moves`
            }
          />
        ))}
      </div>

      <div className="phase-axis">
        <span>Opening</span>
        <span>Midgame</span>
        <span>Endgame</span>
      </div>

      {/* The axis now carries the numbers, so all that is left to say is the
          thing the aggregate genuinely hides: measured on theohwk, short games
          get much worse late (28 to 121 cp) while long games peak in the
          middle and recover. A game that ends early often ends *because* of a
          blunder, so "worse later" is partly a tautology. */}
      <p className="muted small">
        Over {games.toLocaleString()} evaluated{" "}
        {games === 1 ? "game" : "games"} loaded. Games that end early pull the
        later part of the curve up — a short game often ends because of the
        blunder itself.
      </p>
    </div>
  );
}

function GamesTable({ games }: { games: Game[] }) {
  if (games.length === 0) return null;

  const anyEvaluated = games.some((g) => g.acpl != null || g.evalError != null);

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
          {/* Only rendered when at least one loaded game has been evaluated,
              so an un-analysed player does not get two permanently empty
              columns explaining nothing. */}
          {anyEvaluated && <th className="num">Avg loss</th>}
          {anyEvaluated && <th className="num">Blunders</th>}
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
            {anyEvaluated && (
              <td className="num mono" title={
                game.evalError
                  ? "This game's PGN could not be parsed"
                  : game.worstPly != null
                    ? `Worst move at ply ${game.worstPly}, costing ${game.worstLoss} cp`
                    : undefined
              }>
                {game.evalError
                  ? "—"
                  : game.acpl != null
                    ? game.acpl.toFixed(0)
                    : ""}
              </td>
            )}
            {anyEvaluated && (
              <td className="num mono">
                {game.evalError ? "—" : (game.blunders ?? "")}
              </td>
            )}
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
