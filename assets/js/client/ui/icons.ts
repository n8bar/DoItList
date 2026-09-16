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

/**
 * Every class is written out IN FULL. Tailwind finds classes by scanning the
 * source for literal strings, so a class glued together at runtime — "hero-"
 * plus a variable — compiles cleanly, type-checks cleanly, and renders a blank
 * space, because the rule for it was never generated. This map is the only
 * place the client names an icon class, and the a11y test walks it.
 */
export const ICON_CLASS = {
  "arrow-path": "hero-arrow-path",
  bolt: "hero-bolt",
  "signal-slash": "hero-signal-slash",
  "exclamation-triangle": "hero-exclamation-triangle",
  "exclamation-circle": "hero-exclamation-circle",
  "information-circle": "hero-information-circle",
  "check-circle": "hero-check-circle",
  "x-mark": "hero-x-mark",
  "chevron-down": "hero-chevron-down",
} as const;

export type IconName = keyof typeof ICON_CLASS;

export const ICON_NAMES = Object.keys(ICON_CLASS) as readonly IconName[];

/** The stylesheet class for an icon. */
export function iconClass(name: IconName): string {
  return ICON_CLASS[name];
}
