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
