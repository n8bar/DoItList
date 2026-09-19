// The one store primitive the client has (m04.01 item 3.1).
//
// Deliberately tiny and dependency-free: `get` / `set` / `subscribe` over a
// single immutable value. No Redux, no Zustand — the client's state problem is
// four small typed records, not a framework.
//
// JSX-free and React-free on purpose so the semantics (no notify when the
// value is unchanged, unsubscribe is safe mid-notify) are unit-tested by
// `node --test`. The React binding lives in `use_store.ts`.

export type Updater<T> = T | ((previous: T) => T);

export interface Store<T> {
  /** The current value. Always the same object until something calls `set`. */
  get(): T;
  /**
   * Replaces the value. A function updater receives the previous value.
   * Listeners are notified only when the value actually changed (`Object.is`),
   * so a no-op write costs one comparison and nothing else.
   */
  set(updater: Updater<T>): void;
  /** Registers a listener; returns the unsubscribe function. */
  subscribe(listener: () => void): () => void;
}

const isUpdaterFn = <T,>(updater: Updater<T>): updater is (previous: T) => T =>
  typeof updater === "function";

export function createStore<T>(initial: T): Store<T> {
  let value = initial;
  const listeners = new Set<() => void>();

  return {
    get: () => value,

    set(updater) {
      const next = isUpdaterFn(updater) ? updater(value) : updater;
      if (Object.is(next, value)) return;
      value = next;
      // Copy: a listener is allowed to unsubscribe (or subscribe) while we
      // notify without skipping or re-notifying its neighbours.
      for (const listener of [...listeners]) listener();
    },

    subscribe(listener) {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}

/**
 * A read-only view of `source` through `select`, computed once per source
 * value: the result is cached against the source object's identity, so a
 * selector that builds a new object each call still hands back the same one
 * until the source changes. React-free; `use_store.ts` has the hook twin.
 */
export function derive<T, S>(
  source: Pick<Store<T>, "get" | "subscribe">,
  select: (state: T) => S,
): Pick<Store<S>, "get" | "subscribe"> {
  let last: { state: T; value: S } | null = null;
  return {
    get() {
      const state = source.get();
      if (last !== null && Object.is(last.state, state)) return last.value;
      const value = select(state);
      last = { state, value };
      return value;
    },
    subscribe: (listener) => source.subscribe(listener),
  };
}
