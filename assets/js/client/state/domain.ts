// Domain state: what the server said (m04.01 item 3.1).
//
// Canonical server records only — the signed-in user, the Initiative summaries,
// and the Initiative trees that have been loaded, keyed by id. Nothing here
// describes the screen. If a field would change because the user opened a pane,
// selected a row or scrolled, it belongs in `ui.ts`; if it would change because
// the connection dropped, it belongs in `recovery.ts`; if it is a choice the
// user made and expects to survive a reload, it belongs in `preferences.ts`
// (guardrails §7.3 — state lives where its lifetime is).
//
// `state.test.ts` enforces that separation: the four stores' field names must
// stay disjoint.

import type { BootstrapUser } from "../boot.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import type { Store } from "./store.ts";
import { createStore } from "./store.ts";

export interface DomainState {
  /** The signed-in user, or `null` when the session is gone. */
  readonly user: BootstrapUser | null;
  /** The Initiatives index, or `null` before it has ever been read. */
  readonly initiativeSummaries: readonly InitiativeSummary[] | null;
  /** Loaded Initiative trees, keyed by Initiative id. */
  readonly initiativeTrees: Readonly<Record<number, InitiativeTree>>;
}

export const initialDomainState: DomainState = {
  user: null,
  initiativeSummaries: null,
  initiativeTrees: {},
};

export type DomainStore = Store<DomainState>;

export function createDomainStore(initial: Partial<DomainState> = {}): DomainStore {
  return createStore<DomainState>({ ...initialDomainState, ...initial });
}

/** Files one loaded tree, leaving every other loaded tree alone. */
export function putInitiativeTree(store: DomainStore, tree: InitiativeTree): void {
  store.set((state) => ({
    ...state,
    initiativeTrees: { ...state.initiativeTrees, [tree.id]: tree },
  }));
}

/** The loaded tree for `id`, or `undefined` if it has not been read yet. */
export function initiativeTree(state: DomainState, id: number): InitiativeTree | undefined {
  return state.initiativeTrees[id];
}
