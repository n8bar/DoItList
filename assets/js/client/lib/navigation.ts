// Scroll and focus bookkeeping for client routing (m04.01 item 3.3).
//
// Guardrails §7.1: back works and refresh returns you where you were. That is
// only true if *we* remember where "where you were" was — `history.scrollRestoration`
// is set to "manual" precisely because the browser's own guess is wrong once
// the page's content is rendered asynchronously.
//
// Everything here is pure: a list of remembered history entries in and out, and
// a plan describing what the caller should do to the DOM. No `window`, so
// `node --test` covers the part that is easy to get subtly wrong.

/** Which kind of navigation produced the current entry. */
export type NavigationKind = "initial" | "push" | "replace" | "pop";

/** What we remembered about one history entry when the user left it. */
export interface NavigationEntry {
  /** The history entry's key (`history.state.doitKey`). */
  readonly key: string;
  /** The scroll container's `scrollTop` when the user navigated away. */
  readonly scrollTop: number;
  /** The `id` of the element that had focus, or `null` if nothing identifiable did. */
  readonly focusElementId: string | null;
}

/** Most-recently-touched last. Bounded — see `MAX_ENTRIES`. */
export type NavigationMemory = readonly NavigationEntry[];

/**
 * How many history entries we keep scroll/focus for. A long session can push
 * thousands of entries; remembering the last 50 covers every back-button reach
 * a person actually has and keeps the record from growing without bound.
 */
export const MAX_ENTRIES = 50;

export const emptyNavigationMemory: NavigationMemory = [];

/**
 * Records where the user was on `key`. Re-recording an entry moves it to the
 * most-recent end, so trimming drops what was reached longest ago.
 */
export function remember(
  memory: NavigationMemory,
  key: string,
  where: { scrollTop: number; focusElementId: string | null },
): NavigationMemory {
  const kept = memory.filter((entry) => entry.key !== key);
  const next: NavigationEntry[] = [
    ...kept,
    { key, scrollTop: Math.max(0, Math.round(where.scrollTop)), focusElementId: where.focusElementId },
  ];
  return next.length > MAX_ENTRIES ? next.slice(next.length - MAX_ENTRIES) : next;
}

/** What we remembered about `key`, or `undefined` if we never saw it (or trimmed it). */
export function recall(memory: NavigationMemory, key: string): NavigationEntry | undefined {
  return memory.find((entry) => entry.key === key);
}

/** What the caller should do to the DOM after rendering the new route. */
export interface RestorationPlan {
  /** Where to put the scroll container. */
  readonly scrollTop: number;
  /**
   * The element to try to focus first. `null` means "go straight to the route
   * heading" — which is also the fallback when this element is gone.
   */
  readonly focusElementId: string | null;
}

/**
 * A *new* navigation starts at the top with focus on the route's heading, so
 * keyboard and screen-reader users land on the content rather than wherever
 * the previous page's DOM left them.
 *
 * Back/forward instead restores what the user left behind: the scroll position
 * of that entry and, when it still exists, the element that had focus.
 */
export function restorationPlan(
  kind: NavigationKind,
  key: string,
  memory: NavigationMemory,
): RestorationPlan {
  if (kind !== "pop") return { scrollTop: 0, focusElementId: null };
  const entry = recall(memory, key);
  if (!entry) return { scrollTop: 0, focusElementId: null };
  return { scrollTop: entry.scrollTop, focusElementId: entry.focusElementId };
}

/**
 * Resolves a plan against the live DOM, told only whether an id still exists.
 * A remembered element that the new route doesn't render falls back to the
 * heading — never to "nothing", which would leave focus on `<body>`.
 */
export function focusTarget(
  plan: RestorationPlan,
  exists: (id: string) => boolean,
): { kind: "element"; id: string } | { kind: "heading" } {
  const id = plan.focusElementId;
  if (id !== null && exists(id)) return { kind: "element", id };
  return { kind: "heading" };
}
