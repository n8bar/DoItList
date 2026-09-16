// The theme control, as data (m04.01 item 4.7).
//
// The product's theme control is a three-way System / Light / Dark group, and
// it has been since M02 — one press puts the theme where the user asked, with
// the current choice visible without pressing anything. A single button that
// cycles hides two thirds of the answer and makes "which is on?" a thing you
// work out from a label.
//
// What each segment IS — its order, its words, its icon — lives here so the
// component only has to draw it, and so the a11y rules (every segment named,
// every icon real, the group a fixed size whatever is pressed) are unit-tested
// without a browser.

import type { ThemePreference } from "../lib/theme.ts";
import type { IconName } from "../ui/icons.ts";

export interface ThemeSegment {
  readonly preference: ThemePreference;
  /** The word. Rendered `sr-only` beside the icon — an icon is never the name. */
  readonly label: string;
  /** The pointer tooltip, exactly as the LiveView header has it. */
  readonly title: string;
  /** The accessible name, exactly as the LiveView header has it. */
  readonly ariaLabel: string;
  readonly icon: IconName;
}

/** System, Light, Dark — the LiveView's order, words and icons. */
export const THEME_SEGMENTS: readonly ThemeSegment[] = [
  {
    preference: "system",
    label: "System",
    title: "System",
    ariaLabel: "Use system theme",
    icon: "computer-desktop",
  },
  { preference: "light", label: "Light", title: "Light", ariaLabel: "Use light theme", icon: "sun" },
  { preference: "dark", label: "Dark", title: "Dark", ariaLabel: "Use dark theme", icon: "moon" },
];

/** A segment's dom id, derived from the control's — the harness presses these. */
export function themeSegmentId(controlId: string, preference: ThemePreference): string {
  return `${controlId}-${preference}`;
}

/**
 * The wrapper. Nothing here depends on which segment is on, so pressing one
 * cannot change the control's size and shove its neighbours sideways (4.4).
 */
export function themeGroupClass(block = false): string {
  return [
    "inline-flex flex-none items-stretch overflow-hidden rounded-lg border",
    "border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900",
    block ? "w-full" : "",
  ]
    .filter((part) => part !== "")
    .join(" ");
}

export interface SegmentStateOptions {
  /** This is the theme in force. */
  readonly active: boolean;
  /** Index in the group; everything but the first carries the divider. */
  readonly position: number;
}

const SEGMENT_BASE = [
  "inline-flex min-h-11 min-w-11 flex-1 items-center justify-center px-2 py-1.5 text-sm",
  "transition-colors motion-reduce:transition-none",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset",
  "focus-visible:ring-emerald-600 dark:focus-visible:ring-emerald-400",
  "sm:min-h-9 sm:min-w-9",
].join(" ");

// Emerald fill AND a heavier weight: the segment that is on must not be told by
// colour alone (guardrails §4.1).
const SEGMENT_ON = [
  "bg-emerald-600 font-semibold text-white",
  "dark:bg-emerald-600 dark:text-white",
].join(" ");

const SEGMENT_OFF = [
  "font-medium text-zinc-600 hover:bg-zinc-100 hover:text-zinc-900 active:bg-zinc-200",
  "dark:text-zinc-300 dark:hover:bg-zinc-800 dark:hover:text-zinc-50 dark:active:bg-zinc-700",
].join(" ");

const DIVIDER = "border-l border-zinc-300 dark:border-zinc-700";

/** The classes for one segment. */
export function segmentClass({ active, position }: SegmentStateOptions): string {
  return [SEGMENT_BASE, active ? SEGMENT_ON : SEGMENT_OFF, position === 0 ? "" : DIVIDER]
    .filter((part) => part !== "")
    .join(" ");
}
