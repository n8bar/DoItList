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

import type { ApiClient } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import type { DomainStore } from "../state/domain.ts";
import { forgetInitiative, putInitiativeTree } from "../state/domain.ts";
import type { UiStore } from "../state/ui.ts";
import type { ChangedEvent } from "./connection.ts";

export interface RefreshDeps {
  api: ApiClient;
  domain: DomainStore;
}

/**
 * The `onChanged` handler the connection calls. Never throws, never rejects.
 *
 * Two changes in quick succession start two reads, and the network is free to
 * answer them out of order — so each read carries a per-Initiative sequence
 * number and a stale answer is dropped rather than written over a newer tree.
 */
export function createChangedHandler(deps: RefreshDeps): (event: ChangedEvent) => void {
  const { api, domain } = deps;
  const latestTree = new Map<number, number>();
  let latestList = 0;

  return (event: ChangedEvent) => {
    void (async () => {
      const { initiativeId } = event;

      if (domain.get().initiativeTrees[initiativeId] !== undefined) {
        const seq = (latestTree.get(initiativeId) ?? 0) + 1;
        latestTree.set(initiativeId, seq);
        const tree = await api.get<InitiativeTree>(`/initiatives/${initiativeId}`);
        if (tree.ok && latestTree.get(initiativeId) === seq) putInitiativeTree(domain, tree.data);
      }

      if (domain.get().initiativeSummaries !== null) {
        latestList += 1;
        const seq = latestList;
        const list = await api.get<InitiativeSummary[]>("/initiatives");
        if (list.ok && latestList === seq) {
          domain.set((state) => ({ ...state, initiativeSummaries: list.data }));
        }
      }
    })();
  };
}

export interface RevokedDeps {
  domain: DomainStore;
  ui: UiStore;
  /** Hands the app the "you don't have access" screen. */
  onForbidden(): void;
}

/**
 * What the client does when access to an Initiative is taken away mid-session
 * (m04.01 1.5). The copy it is holding goes — including the row in the index —
 * and, if that Initiative is the screen the user is on, the app says so rather
 * than leaving a tree on the glass that the server would now refuse.
 */
export function createRevokedHandler(deps: RevokedDeps): (initiativeId: number) => void {
  const { domain, ui, onForbidden } = deps;

  return (initiativeId: number) => {
    forgetInitiative(domain, initiativeId);
    const route = ui.get().route;
    if (route.kind === "initiative" && route.id === initiativeId) onForbidden();
  };
}
