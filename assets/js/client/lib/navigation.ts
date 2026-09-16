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

// --- Restoring a scroll position against content that arrives late -----------
//
// A remembered position can't always be honoured on the first try: if the route
// being restored has to fetch, the container is still short and the browser
// clamps `scrollTop = 420` down to 0. Nothing about the first attempt is wrong;
// it is simply too early. So restoring is a small, bounded conversation instead
// of a single assignment — the caller re-runs `restoreStep` whenever the
// content changes, and this decides whether to try again, and when to give up.
//
// Two things it will not do: keep watching forever, and move a container the
// user has since scrolled themselves.

/** How many attempts a single restore gets before it gives up. */
export const MAX_RESTORE_ATTEMPTS = 24;

/** How long a restore keeps watching for late content, in milliseconds. */
export const RESTORE_TIMEOUT_MS = 3000;

export interface RestoreState {
  /** The position we are trying to reach. */
  readonly target: number;
  readonly attempts: number;
  /** The `scrollTop` we last set, or `null` before the first attempt. */
  readonly applied: number | null;
  /** True once nothing more will be attempted. */
  readonly finished: boolean;
}

/** What the container looks like right now. */
export interface ScrollMetrics {
  readonly scrollTop: number;
  readonly scrollHeight: number;
  readonly clientHeight: number;
}

export interface RestoreStep {
  /** The `scrollTop` to set now, or `null` to leave the container alone. */
  readonly apply: number | null;
  /** True when the caller should stop watching for more content. */
  readonly finished: boolean;
  readonly state: RestoreState;
}

export function beginRestore(target: number): RestoreState {
  return { target: Math.max(0, Math.round(target)), attempts: 0, applied: null, finished: false };
}

/**
 * One attempt. Call it as soon as the route has rendered, then again each time
 * the content changes.
 *
 *   * The container is tall enough → set the target and finish.
 *   * The container is still short → set as far as it goes and stay open, so a
 *     fetch that lands a moment later finishes the job.
 *   * The `scrollTop` isn't where we left it → the user scrolled; stop, and
 *     don't touch it. Their scroll outranks our memory of an old one.
 *   * Out of attempts → stop. A route whose content never grows must not leave
 *     a watcher running for the rest of the session.
 */
export function restoreStep(state: RestoreState, metrics: ScrollMetrics): RestoreStep {
  if (state.finished) return { apply: null, finished: true, state };

  if (state.applied !== null && metrics.scrollTop !== state.applied) {
    const stopped = { ...state, finished: true };
    return { apply: null, finished: true, state: stopped };
  }

  const attempts = state.attempts + 1;
  const maxScroll = Math.max(0, metrics.scrollHeight - metrics.clientHeight);
  const reachable = Math.min(state.target, maxScroll);
  const arrived = reachable >= state.target;
  const finished = arrived || attempts >= MAX_RESTORE_ATTEMPTS;

  return {
    apply: reachable,
    finished,
    state: { target: state.target, attempts, applied: reachable, finished },
  };
}
