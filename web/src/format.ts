/** Formatting shared by more than one screen. */

/** "3h ago" from epoch seconds, or a dash when there is no time. */
export function ago(seconds: number | null): string {
  if (!seconds) return "—";
  const delta = Date.now() / 1000 - seconds;
  if (delta < 60) return "just now";
  if (delta < 3600) return `${Math.floor(delta / 60)}m ago`;
  if (delta < 86400) return `${Math.floor(delta / 3600)}h ago`;
  return `${Math.floor(delta / 86400)}d ago`;
}
