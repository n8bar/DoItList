// The history adapter behind client routing (m04.01 items 3.2–3.3).
//
// `pushState` / `replaceState` / `popstate`, and nothing else — no history
// library. Its one non-obvious job is to stamp every entry with a stable key
// (`history.state.doitKey`) so scroll and focus can be remembered *per entry*
// rather than per path: the same Initiative visited twice is two entries, and
// back should return to each one's own scroll position.
//
// The browser objects are injected, so the whole thing is unit-tested under
// `node --test` with a fake history.

import type { NavigationKind } from "../lib/navigation.ts";

/** The subset of `window.history` this adapter uses. */
export interface HistoryLike {
  readonly state: unknown;
  pushState(data: unknown, unused: string, url: string): void;
  replaceState(data: unknown, unused: string, url: string): void;
  scrollRestoration?: "auto" | "manual";
}

export interface HistoryEnv {
  history: HistoryLike;
  location: { readonly pathname: string };
  /** Registers a `popstate` listener; returns the unsubscribe function. */
  addPopStateListener(listener: (state: unknown) => void): () => void;
  /** Injected in tests; defaults to a random key. */
  makeKey?: () => string;
}

export interface HistoryEntry {
  readonly path: string;
  readonly key: string;
  readonly kind: NavigationKind;
}

export interface ClientHistory {
  /** The entry the browser is on right now. */
  current(): HistoryEntry;
  /** A new entry. Back returns to the one we were on. */
  push(path: string): void;
  /** Replaces the current entry — back skips over it (used for `/app`). */
  replace(path: string): void;
  /** Notified on push, replace and popstate. Returns the unsubscribe function. */
  listen(listener: (entry: HistoryEntry) => void): () => void;
  /** Drops the `popstate` listener. */
  dispose(): void;
}

const KEY_FIELD = "doitKey";

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** The key stamped on a history state, or `null` if it isn't ours. */
export function keyOf(state: unknown): string | null {
  if (!isRecord(state)) return null;
  const key = state[KEY_FIELD];
  return typeof key === "string" && key !== "" ? key : null;
}

/** A history state carrying `key`, preserving anything else already on it. */
export function stateWithKey(state: unknown, key: string): Record<string, unknown> {
  return { ...(isRecord(state) ? state : {}), [KEY_FIELD]: key };
}

/**
 * One path form for every entry. `popstate` reports `location.pathname`, which
 * carries neither a query string nor a fragment; a pushed `to` might. Both go
 * through here so an entry's `path` means the same thing however it was made.
 */
export function normalizePath(path: string): string {
  const withoutFragment = path.split("#", 1)[0] ?? "";
  const withoutQuery = withoutFragment.split("?", 1)[0] ?? "";
  return withoutQuery === "" ? "/" : withoutQuery;
}

let counter = 0;

function defaultMakeKey(): string {
  counter += 1;
  return `k${Date.now().toString(36)}-${counter.toString(36)}`;
}

export function createClientHistory(env: HistoryEnv): ClientHistory {
  const makeKey = env.makeKey ?? defaultMakeKey;
  const listeners = new Set<(entry: HistoryEntry) => void>();

  // We own scroll restoration: the browser restores before our route has
  // rendered its content, which lands the user at the top anyway (or worse,
  // somewhere arbitrary). `lib/navigation.ts` decides instead.
  if ("scrollRestoration" in env.history) env.history.scrollRestoration = "manual";

  // A direct load or a refresh arrives with either no state at all or the key
  // we stamped before the reload. Adopt it, so refresh really does come back to
  // the same entry rather than minting a fresh one with no memory.
  const existing = keyOf(env.history.state);
  let entry: HistoryEntry = {
    path: normalizePath(env.location.pathname),
    key: existing ?? makeKey(),
    kind: "initial",
  };
  if (existing === null) {
    env.history.replaceState(stateWithKey(env.history.state, entry.key), "", entry.path);
  }

  const emit = (next: HistoryEntry) => {
    entry = next;
    for (const listener of [...listeners]) listener(entry);
  };

  const unlisten = env.addPopStateListener((state) => {
    emit({
      path: normalizePath(env.location.pathname),
      key: keyOf(state) ?? makeKey(),
      kind: "pop",
    });
  });

  return {
    current: () => entry,

    push(path) {
      const key = makeKey();
      env.history.pushState(stateWithKey(null, key), "", path);
      emit({ path: normalizePath(path), key, kind: "push" });
    },

    replace(path) {
      // A fresh key: the replaced entry's remembered scroll belonged to content
      // the user will never see again.
      const key = makeKey();
      env.history.replaceState(stateWithKey(null, key), "", path);
      emit({ path: normalizePath(path), key, kind: "replace" });
    },

    listen(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },

    dispose() {
      listeners.clear();
      unlisten();
    },
  };
}

/** The adapter wired to the real browser. */
export function browserHistoryEnv(): HistoryEnv {
  return {
    history: window.history,
    location: window.location,
    addPopStateListener(listener) {
      const handler = (event: PopStateEvent) => listener(event.state);
      window.addEventListener("popstate", handler);
      return () => window.removeEventListener("popstate", handler);
    },
  };
}
