// Which branches are closed, as a branch reads it (m04.02 item 7.9.1).
//
// The closed set used to live in the tree hook's React state and reach every
// row through the context: one toggle gave the context a new identity and
// redrew the whole tree. Now it is a small store of its own, and each chevron
// and children list subscribes for its one branch — as rows read the
// selection since 2.2.3 — so a toggle redraws that branch alone. The hook
// still reads the whole set (keyboard walks, pruning) from the same store:
// one source of truth, two ways to read it.

import type { Store } from "../state/store.ts";
import { createStore } from "../state/store.ts";

export type CollapsedSet = ReadonlySet<number>;

/** The closed set as a branch reads it: its own answer, and a way to hear it change. */
export interface Collapsed {
  get(id: number): boolean;
  subscribe(listener: () => void): () => void;
}

export type CollapseSetStore = Store<CollapsedSet>;

export function createCollapseStore(initial: CollapsedSet = EMPTY): CollapseSetStore {
  return createStore<CollapsedSet>(initial);
}

/** A `Collapsed` over the store. Stable: one object for the store's whole life. */
export function collapsedOf(store: CollapseSetStore): Collapsed {
  return {
    get: (id) => store.get().has(id),
    subscribe: (listener) => store.subscribe(listener),
  };
}

/** Closes or opens `id`. A write that changes nothing keeps the set's identity. */
export function setCollapsedIn(store: CollapseSetStore, id: number, collapsed: boolean): void {
  store.set((current) => {
    if (current.has(id) === collapsed) return current;
    const next = new Set(current);
    if (collapsed) next.add(id);
    else next.delete(id);
    return next;
  });
}

const EMPTY: CollapsedSet = new Set<number>();
