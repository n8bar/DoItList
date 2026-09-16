// What the client does when the server says something changed (m04.01 item 1.5).
//
// Deliberately blunt: the channel carries no tree, so a `changed` is a signal
// to re-read the Initiative through the ordinary `/app/api` path — the same
// read the screen made on mount, through the same client. Arc 3 replaces this
// with a delta envelope; until it does, refetching is the honest version and it
// is one round trip on a change the user can see.
//
// The Initiatives list has no topic of its own yet, so a change on an
// Initiative the tab is watching also refreshes the list — but only when the
// list has actually been read, so a deep link never fetches a screen nobody
// asked for.
//
// Refetching and revocation are ONE unit (`createInitiativeSync`), because they
// race: a read already in flight when access is taken away would otherwise
// resolve afterwards and quietly write the tree back. They share a sequence, so
// revoking is also an invalidation.

import type { ApiClient } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import type { DomainStore } from "../state/domain.ts";
import { forgetInitiative, putInitiativeTree } from "../state/domain.ts";
import type { UiStore } from "../state/ui.ts";
import type { ChangedEvent } from "./connection.ts";

/**
 * Who is allowed to write what a read came back with.
 *
 * Every read claims a sequence before it starts and must still hold the newest
 * one to land. Anything that makes older reads wrong — a newer read, or access
 * being taken away — bumps the sequence, and the loser is dropped on arrival
 * rather than written over the truth. A read begun *after* a revocation (the
 * user was let back in) claims a fresh sequence and lands normally, so nothing
 * needs to be un-revoked.
 */
export interface SyncGuard {
  /** Claim a sequence for a read of `id`'s tree. */
  beginTree(id: number): number;
  /** Claim a sequence for a read of the Initiatives index. */
  beginList(): number;
  /** May a tree read holding `seq` still write? */
  currentTree(id: number, seq: number): boolean;
  /** May a list read holding `seq` still write? */
  currentList(seq: number): boolean;
  /** Access to `id` is gone: every read in flight for it, and for the index. */
  revoke(id: number): void;
}

export function createSyncGuard(): SyncGuard {
  const trees = new Map<number, number>();
  let list = 0;

  const bumpTree = (id: number): number => {
    const seq = (trees.get(id) ?? 0) + 1;
    trees.set(id, seq);
    return seq;
  };

  return {
    beginTree: bumpTree,
    beginList: () => (list += 1),
    currentTree: (id, seq) => trees.get(id) === seq,
    currentList: (seq) => list === seq,
    revoke(id) {
      // The index carries a row for `id` too, so a list read from before the
      // revocation would put it straight back.
      bumpTree(id);
      list += 1;
    },
  };
}

export interface SyncDeps {
  api: ApiClient;
  domain: DomainStore;
  ui: UiStore;
  /** Hands the app the "you don't have access" screen. */
  onForbidden(): void;
  /** Injected in tests; one is made per client otherwise. */
  guard?: SyncGuard;
}

export interface InitiativeSync {
  /** For `Connection.onChanged`. Never throws, never rejects. */
  onChanged(event: ChangedEvent): void;
  /** For `Connection.onAccessRevoked`. */
  onAccessRevoked(initiativeId: number): void;
}

/**
 * The client's two answers to the live channel, built together so they cannot
 * be wired up with separate state (m04.01 1.5).
 *
 *   * a change — re-read what we are holding, newest answer wins;
 *   * access taken away — forget the copy we hold, including the row in the
 *     index, invalidate anything still in flight for it, and, if that
 *     Initiative is the screen the user is on, say so rather than leaving a
 *     tree on the glass that the server would now refuse.
 */
export function createInitiativeSync(deps: SyncDeps): InitiativeSync {
  const { api, domain, ui, onForbidden } = deps;
  const guard = deps.guard ?? createSyncGuard();

  return {
    onChanged(event: ChangedEvent) {
      void (async () => {
        const { initiativeId } = event;

        if (domain.get().initiativeTrees[initiativeId] !== undefined) {
          const seq = guard.beginTree(initiativeId);
          const tree = await api.get<InitiativeTree>(`/initiatives/${initiativeId}`);
          if (tree.ok && guard.currentTree(initiativeId, seq)) putInitiativeTree(domain, tree.data);
        }

        if (domain.get().initiativeSummaries !== null) {
          const seq = guard.beginList();
          const list = await api.get<InitiativeSummary[]>("/initiatives");
          if (list.ok && guard.currentList(seq)) {
            domain.set((state) => ({ ...state, initiativeSummaries: list.data }));
          }
        }
      })();
    },

    onAccessRevoked(initiativeId: number) {
      guard.revoke(initiativeId);
      forgetInitiative(domain, initiativeId);
      const route = ui.get().route;
      if (route.kind === "initiative" && route.id === initiativeId) onForbidden();
    },
  };
}
