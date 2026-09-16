// Ephemeral view state: what the screen is doing right now (m04.01 item 3.1).
//
// Everything here dies with the tab and the server never hears about it
// (guardrails §7.3): which route is showing, what is selected, which panes are
// open, where focus should land, and the per-history-entry scroll/focus memory
// that makes back/forward feel like the browser (item 3.3).
//
// Nothing here is a server record, and no server record is here — `state.test.ts`
// holds that line.

import type { NavigationMemory } from "../lib/navigation.ts";
import { emptyNavigationMemory, remember } from "../lib/navigation.ts";
import type { Route } from "../router/route.ts";
import type { Store } from "./store.ts";
import { createStore } from "./store.ts";

export interface UiState {
  /** The route currently rendered. The router is the only writer. */
  readonly route: Route;
  /** The selected task, if any. Arc 2 drives this. */
  readonly selectedTaskId: number | null;
  /** Open panes/disclosures, by a stable client-side key. */
  readonly openPanes: readonly string[];
  /**
   * The element id focus should move to after the next render, or `null` for
   * "the route's heading". Consumed and cleared by the router.
   */
  readonly focusTarget: string | null;
  /** Scroll position and last-focused element, per history entry (item 3.3). */
  readonly navigationMemory: NavigationMemory;
}

export const initialUiState: UiState = {
  route: { kind: "initiatives" },
  selectedTaskId: null,
  openPanes: [],
  focusTarget: null,
  navigationMemory: emptyNavigationMemory,
};

export type UiStore = Store<UiState>;

export function createUiStore(initial: Partial<UiState> = {}): UiStore {
  return createStore<UiState>({ ...initialUiState, ...initial });
}

export function setRoute(store: UiStore, route: Route): void {
  store.set((state) => (state.route === route ? state : { ...state, route }));
}

/** Records where the user was on `key` before leaving it. */
export function rememberPlace(
  store: UiStore,
  key: string,
  where: { scrollTop: number; focusElementId: string | null },
): void {
  store.set((state) => ({
    ...state,
    navigationMemory: remember(state.navigationMemory, key, where),
  }));
}
