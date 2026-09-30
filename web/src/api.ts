/**
 * The API client. One place that knows the base URL and how a token is
 * attached, so no component builds a fetch by hand.
 *
 * The split that matters here is authenticated vs public, and it mirrors the
 * gateway exactly: POST /games carries a bearer token because the route has a
 * JWT authorizer, and every read route does not because analysis is public
 * shared data. Sending a token to a public route would be harmless but
 * misleading - it would suggest the read is gated when it is not.
 */
import { fetchAuthSession } from "aws-amplify/auth";

const BASE = import.meta.env.VITE_API_URL;

if (!BASE) {
  throw new Error("Missing VITE_API_URL - copy .env.example to .env");
}

/** What the API returned when it refused. */
export class ApiError extends Error {
  // Declared and assigned separately rather than as a constructor parameter
  // property: the tsconfig sets erasableSyntaxOnly, which rejects any TS
  // syntax that emits runtime code. That is what lets the build strip types
  // rather than transform them.
  readonly status: number;
  /**
   * The parsed error body, when there was one. Carries fields a caller may
   * need to act on rather than only display - `retryAfter` on a 429 from the
   * analyse rate limit is the reason this exists.
   */
  readonly body: unknown;

  constructor(status: number, message: string, body?: unknown) {
    super(message);
    this.status = status;
    this.body = body;
  }
}

async function parse(response: Response) {
  const text = await response.text();
  let body: unknown;
  try {
    body = text ? JSON.parse(text) : {};
  } catch {
    // A non-JSON body means the gateway answered rather than a handler -
    // a 429 from the stage throttle, or a 504. Surface the status.
    throw new ApiError(response.status, text || response.statusText);
  }

  if (!response.ok) {
    const error =
      (body as { error?: string }).error ??
      (body as { message?: string }).message ??
      response.statusText;
    throw new ApiError(response.status, error, body);
  }

  return body;
}

/**
 * The current access token, or throws if there is no session.
 *
 * fetchAuthSession refreshes silently when the access token has expired but
 * the refresh token has not - which is why this is called per request rather
 * than a token being captured once at sign-in. An access token lasts hours; a
 * page left open outlasts it.
 */
async function authHeader(): Promise<Record<string, string>> {
  const session = await fetchAuthSession();
  const token = session.tokens?.accessToken?.toString();
  if (!token) {
    throw new ApiError(401, "not signed in");
  }
  return { Authorization: `Bearer ${token}` };
}

// --- Response shapes -------------------------------------------------------
// Mirrors of what the handlers return. Kept as types rather than validated at
// runtime: this client and those handlers ship together, so a mismatch is a
// deploy bug to fix rather than a case to handle.

export interface MonthSummary {
  games: number;
  wins: number;
  losses: number;
  draws: number;
  asWhite: number;
  asBlack: number;
  byClass: Record<string, number>;
  ratingMin?: number;
  ratingMax?: number;
  ratingLast?: number;
}

export interface Month {
  archive: string;
  status: "PENDING" | "COMPLETE" | "FAILED";
  summary?: MonthSummary;
  error?: string;
  analysedAt?: number;
  checkedAt?: number;
}

export interface PlayerTotals extends Omit<MonthSummary, "ratingLast"> {
  months: number;
  winRate?: number;
}

/**
 * The second statistics group, derived server-side from the game items rather
 * than stored on any month.
 *
 * `status` on a Month says whether it was *ingested*; it has never said
 * whether it was evaluated, and deliberately still does not. Read this
 * instead.
 *
 * `inScope` is the denominator for progress - not the player's total game
 * count, because evaluation is capped per time control and excludes daily.
 * `excluded` games are not a backlog: they will never be evaluated.
 */
export interface EvaluationState {
  evaluated: number;
  outstanding: number;
  inScope: number;
  byClass: Record<string, number>;
  excluded: Record<string, number>;
  /**
   * No longer sent. It flagged `excluded` as partial when selection stopped
   * early; `excluded` now comes from the month summaries and is always the
   * player's whole history. Kept optional so an older API still type-checks.
   */
  excludedPartial?: boolean;
  /**
   * A run is in flight for this player, by anyone - read from the server's
   * per-player claim, so it survives a refresh and shows in a second tab.
   * Optional so an older API still type-checks.
   */
  running?: boolean;
  depth: number;
}

export interface PlayerResponse {
  player: string;
  totals: PlayerTotals;
  pending: number;
  evaluation: EvaluationState;
  months: Month[];
}

export interface DirectoryEntry {
  platform: string;
  username: string;
  months: number;
  complete: number;
  pending: number;
  games: number;
  lastAnalysedAt: number | null;
}

export interface DirectoryResponse {
  players: DirectoryEntry[];
  count: number;
  truncated: boolean;
}

export interface Game {
  url: string;
  end: number;
  /** Single letter, not a word - the row is byte-budgeted (see worker.py). */
  colour: "w" | "b";
  /** Chess.com's per-side result: "win", "resigned", "agreed", "timeout", ... */
  result: string;
  rating: number;
  opp: string;
  oppRating: number;
  /** Chess.com's raw time control, e.g. "180", "600+5", "1/259200". */
  tc: string;
  class: string;

  // --- Evaluation, present only on games Stockfish has finished -------------
  //
  // The per-ply `evals` array and the PGN are deliberately NOT sent: the
  // dashboard shows aggregates and worst-game ranking, and the move-by-move
  // view is the thing this project decided not to build. Together they were
  // 76% of a game row.

  /** Average centipawn loss. The headline number for a single game. */
  acpl?: number;
  blunders?: number;
  mistakes?: number;
  inaccuracies?: number;
  /** Ply index of the single worst move, and what it cost in centipawns. */
  worstPly?: number;
  worstLoss?: number;
  /**
   * Centipawn loss bucketed across the course of the game, ten buckets, as
   * summed loss and move count per bucket rather than averages.
   *
   * Sums and counts, because averaging per-game averages would weight a
   * 12-move miniature the same as a 90-move grind. Divide the summed loss by
   * the summed count across games instead.
   *
   * Buckets are a *percentage of the game*, not fixed move numbers: 56% of
   * games never reach move 31, so fixed boundaries measured the endgame over
   * fewer than half the games and flattered it. By percentage every game
   * contributes to every bucket.
   */
  phaseLoss?: number[];
  phaseCount?: number[];
  /** Set on success and on an unparseable game - both mean "not retried". */
  evalDepth?: number;
  evaluatedAt?: number;
  /** Present instead of the numbers when the PGN could not be parsed. */
  evalError?: string;
}

/**
 * Draws, spelled the way Chess.com spells them. Mirrors DRAW_RESULTS in
 * worker.py - "win" is a win, these are draws, everything else is a loss.
 * Duplicated rather than derived because the aggregate is server-side; this
 * copy exists only to colour a row in a list.
 */
export const DRAW_RESULTS = new Set([
  "agreed",
  "repetition",
  "stalemate",
  "insufficient",
  "50move",
  "timevsinsufficient",
]);

export function outcomeOf(result: string): "win" | "draw" | "loss" {
  if (result === "win") return "win";
  return DRAW_RESULTS.has(result) ? "draw" : "loss";
}

/**
 * One archive with its games attached.
 *
 * The month is a storage and worker concept, not a product one - the UI shows
 * a player's games as one continuous list. This type exists because the month
 * is still the *fetch* unit: games are stored one item per archive (which is
 * what keeps an 828-game month inside a 400KB item), so the games list pages
 * by walking archives newest-first rather than by an offset.
 *
 * That is the whole of the compromise. The user never sees an archive; the
 * network tab does.
 */
export interface MonthDetail {
  id: string;
  archive: string;
  platform: string;
  username: string;
  status: "PENDING" | "COMPLETE" | "FAILED";
  games?: Game[];
  summary?: MonthSummary;
  error?: string;
  analysedAt?: number;
  checkedAt?: number;
  lastCheckHit?: boolean;
}

export interface SubmitResponse {
  player: string;
  archives: number;
  queued: number;
  skipped: number;
  refreshed: boolean;
  statusUrl: string;
}

// --- Calls -----------------------------------------------------------------

/** Submit a whole player for ingestion. The one authenticated call. */
export async function submitPlayer(username: string): Promise<SubmitResponse> {
  const response = await fetch(`${BASE}/games`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(await authHeader()),
    },
    body: JSON.stringify({ username, platform: "chesscom" }),
  });
  return (await parse(response)) as SubmitResponse;
}

/**
 * The 202 from POST /analyse.
 *
 * `queued` is work started, `skipped` is games already evaluated at this depth
 * (the dedup, which is what makes re-analysing free), `excluded` is games that
 * will never be evaluated - daily, where centipawn loss measures the player's
 * engine rather than their judgement.
 *
 * `alreadyQueued` appears instead of queued>0 when a run for this player is
 * already in flight: the request is refused, and no rate-limit token is spent.
 */
export interface AnalyseResponse {
  player: string;
  queued: number;
  skipped: number;
  byClass: Record<string, number>;
  excluded: Record<string, number>;
  alreadyQueued?: number;
  statusUrl: string;
}

/**
 * Ask for a player's recent games to be evaluated. Authenticated, and the one
 * call that spends real money.
 *
 * A 429 carries `retryAfter` seconds - the token bucket is per account, five
 * tokens refilling one an hour, and it is charged only when a request actually
 * queues work.
 */
export async function analysePlayer(
  username: string,
  platform = "chesscom",
): Promise<AnalyseResponse> {
  const response = await fetch(`${BASE}/analyse`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      ...(await authHeader()),
    },
    body: JSON.stringify({ username, platform }),
  });
  return (await parse(response)) as AnalyseResponse;
}

/** Every player anyone has submitted. Public. */
export async function listPlayers(): Promise<DirectoryResponse> {
  return (await parse(await fetch(`${BASE}/players`))) as DirectoryResponse;
}

/** One player's months and cumulative totals. Public. */
export async function getPlayer(
  platform: string,
  username: string,
): Promise<PlayerResponse> {
  const response = await fetch(
    `${BASE}/player/${encodeURIComponent(platform)}/${encodeURIComponent(username)}`,
  );
  return (await parse(response)) as PlayerResponse;
}

/** One month, with its games. Public. */
export async function getMonth(
  platform: string,
  username: string,
  archive: string,
): Promise<MonthDetail> {
  const response = await fetch(
    `${BASE}/analysis/${encodeURIComponent(platform)}/${encodeURIComponent(username)}/${encodeURIComponent(archive)}`,
  );
  return (await parse(response)) as MonthDetail;
}
