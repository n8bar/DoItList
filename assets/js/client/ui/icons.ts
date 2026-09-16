// The icon vocabulary (items 4.2–4.3).
//
// The client shares the LiveView's stylesheet, so it shares its icons: the
// `hero-*` classes the heroicons plugin generates from `assets/css/app.css`.
// Naming them in one typed union is what stops a typo becoming an invisible
// icon — `hero-bolt` renders, `hero-blot` renders nothing at all, and neither
// the compiler nor the eye catches it in a class string.
//
// An icon is NEVER the only cue. Every control and state that uses one also
// carries text (guardrails §4.1, spec §7).

export const ICON_NAMES = [
  "arrow-path",
  "bolt",
  "signal-slash",
  "exclamation-triangle",
  "exclamation-circle",
  "information-circle",
  "check-circle",
  "x-mark",
  "chevron-down",
] as const;

export type IconName = (typeof ICON_NAMES)[number];

/** The stylesheet class for an icon. */
export function iconClass(name: IconName): string {
  return `hero-${name}`;
}
