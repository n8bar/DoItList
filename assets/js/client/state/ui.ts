// Ephemeral view state: what the screen is doing right now (m04.01 item 3.1).
//
// Everything here dies with the tab and the server never hears about it
// (guardrails §7.3): which route is showing, what is selected, which panes are
// open, and the per-history-entry scroll/focus memory that makes back/forward
// feel like the browser (item 3.3).
//
// Nothing here is a server record, and no server record is here — `state.test.ts`
// holds that line.

import type { NavigationMemory } from "../lib/navigation.ts";
import { emptyNavigationMemory, remember } from "../lib/navigation.ts";
import type { Notice, NoticeKind } from "./notices.ts";
import { addNotice, findDuplicate, removeNotice } from "./notices.ts";
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
  /** Scroll position and last-focused element, per history entry (item 3.3). */
  readonly navigationMemory: NavigationMemory;
  /** After-the-fact lines shown in the notice region, newest first (item 4.3). */
  readonly notices: readonly Notice[];
}

export const initialUiState: UiState = {
  route: { kind: "initiatives" },
  selectedTaskId: null,
  openPanes: [],
  navigationMemory: emptyNavigationMemory,
  notices: [],
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

export interface NoticeInput {
  readonly kind: NoticeKind;
  readonly message: string;
  readonly title?: string;
  /** Supply one to make a notice replaceable (and to make tests deterministic). */
  readonly id?: string;
}

let noticeSeq = 0;

/**
 * Shows a notice and returns its id, so the caller can dismiss the exact one it
 * raised. A message already showing is not raised twice — the id that comes
 * back is the showing one's.
 */
export function pushNotice(store: UiStore, input: NoticeInput): string {
  const existing = findDuplicate(store.get().notices, input.kind, input.message);
  if (existing !== null) return existing.id;

  noticeSeq += 1;
  const notice: Notice = {
    id: input.id ?? `notice-${noticeSeq}`,
    kind: input.kind,
    title: input.title ?? null,
    message: input.message,
  };
  store.set((state) => ({ ...state, notices: addNotice(state.notices, notice) }));
  return notice.id;
}

export function dismissNotice(store: UiStore, id: string): void {
  store.set((state) => {
    const notices = removeNotice(state.notices, id);
    return notices === state.notices ? state : { ...state, notices };
  });
}
