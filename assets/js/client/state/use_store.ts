// The React binding for `store.ts` (m04.01 item 3.1).
//
// `useSyncExternalStore` is the whole implementation: it is React's own
// contract for state that lives outside React, which is exactly what these
// stores are — they survive a route change, an unmount and a remount, because
// the stores are created once at boot and the views come and go.
//
// Kept in its own file so `store.ts` stays React-free and `node --test`-able.

import { useCallback, useRef, useSyncExternalStore } from "react";

import type { Store } from "./store.ts";

/** Subscribes to the whole value. Re-renders whenever the store changes. */
export function useStore<T>(store: Store<T>): T {
  return useSyncExternalStore(store.subscribe, store.get, store.get);
}

/**
 * Subscribes to one derived value. The result is cached against the state
 * object's identity, so a selector that builds a new array or object each call
 * still satisfies `useSyncExternalStore`'s "same snapshot until it changes"
 * requirement.
 */
export function useStoreValue<T, S>(store: Store<T>, selector: (state: T) => S): S {
  const cache = useRef<{ state: T; value: S } | null>(null);

  const getSnapshot = useCallback(() => {
    const state = store.get();
    const cached = cache.current;
    if (cached !== null && Object.is(cached.state, state)) return cached.value;
    const value = selector(state);
    cache.current = { state, value };
    return value;
  }, [store, selector]);

  return useSyncExternalStore(store.subscribe, getSnapshot, getSnapshot);
}
