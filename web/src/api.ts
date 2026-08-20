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

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
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
    throw new ApiError(response.status, error);
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

export interface PlayerResponse {
  player: string;
  totals: PlayerTotals;
  pending: number;
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
 * The month route returns the stored item as-is (minus the keys), so this is
 * a superset of Month with the games attached.
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
