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
import type { InitiativeSummary, Member } from "../api/types.ts";
import type { TreeModel } from "../tree/model.ts";
import type { NotificationsState } from "./notifications.ts";
import { emptyNotifications } from "./notifications.ts";
import type { Store } from "./store.ts";
import { createStore } from "./store.ts";

export interface DomainState {
  /** The signed-in user, or `null` when the session is gone. */
  readonly user: BootstrapUser | null;
  /** The Initiatives index, or `null` before it has ever been read. */
  readonly initiativeSummaries: readonly InitiativeSummary[] | null;
  /**
   * Loaded Initiative trees, keyed by Initiative id, in the client's own
   * normalized form (`tree/model.ts`) — records by id and child order by
   * parent. The nested read the server sent is not kept.
   */
  readonly trees: Readonly<Record<number, TreeModel>>;
  /**
   * Each loaded Initiative's members, keyed by Initiative id. Its own field
   * rather than part of the tree: membership is read separately, changes on its
   * own schedule, and a tree refetch must not blank the avatars (item 1.2.2).
   */
  readonly members: Readonly<Record<number, readonly Member[]>>;
  /** The bell's rows and unread count — server records, like the rest (4.6). */
  readonly notifications: NotificationsState;
}

export const initialDomainState: DomainState = {
  user: null,
  initiativeSummaries: null,
  trees: {},
  members: {},
  notifications: emptyNotifications,
};

export type DomainStore = Store<DomainState>;

export function createDomainStore(initial: Partial<DomainState> = {}): DomainStore {
  return createStore<DomainState>({ ...initialDomainState, ...initial });
}

/** Files one loaded tree, leaving every other loaded tree alone. */
export function putTree(store: DomainStore, tree: TreeModel): void {
  store.set((state) => ({
    ...state,
    trees: { ...state.trees, [tree.initiativeId]: tree },
  }));
}

/** Files one Initiative's member list, leaving every other one alone. */
export function putMembers(store: DomainStore, id: number, members: readonly Member[]): void {
  store.set((state) => ({ ...state, members: { ...state.members, [id]: members } }));
}

/**
 * Forgets everything the client holds about one Initiative — the loaded tree
 * and its row in the index. Used when the server says the user may no longer
 * see it (m04.01 1.5): access that has been taken away must not leave a copy
 * of the data on the glass.
 */
export function forgetInitiative(store: DomainStore, id: number): void {
  store.set((state) => {
    const trees = { ...state.trees };
    delete trees[id];
    const members = { ...state.members };
    delete members[id];
    const summaries = state.initiativeSummaries;
    return {
      ...state,
      trees,
      members,
      initiativeSummaries:
        summaries === null ? null : summaries.filter((summary) => summary.id !== id),
    };
  });
}

/**
 * Applies a pure notifications change (`state/notifications.ts`) to the store.
 * The rules live there; this only files the result.
 */
export function updateNotifications(
  store: DomainStore,
  change: (state: NotificationsState) => NotificationsState,
): void {
  store.set((state) => {
    const notifications = change(state.notifications);
    return notifications === state.notifications ? state : { ...state, notifications };
  });
}

/** One Initiative's members, or an empty list before they have been read. */
export function members(state: DomainState, id: number): readonly Member[] {
  return state.members[id] ?? EMPTY_MEMBERS;
}

const EMPTY_MEMBERS: readonly Member[] = [];

/** The loaded tree for `id`, or `undefined` if it has not been read yet. */
export function tree(state: DomainState, id: number): TreeModel | undefined {
  return state.trees[id];
}
