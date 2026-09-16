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
import { putInitiativeTree } from "../state/domain.ts";
import type { ChangedEvent } from "./connection.ts";

export interface RefreshDeps {
  api: ApiClient;
  domain: DomainStore;
}

/** The `onChanged` handler the connection calls. Never throws, never rejects. */
export function createChangedHandler(deps: RefreshDeps): (event: ChangedEvent) => void {
  const { api, domain } = deps;

  return (event: ChangedEvent) => {
    void (async () => {
      const held = domain.get().initiativeTrees[event.initiativeId] !== undefined;
      if (held) {
        const tree = await api.get<InitiativeTree>(`/initiatives/${event.initiativeId}`);
        if (tree.ok) putInitiativeTree(domain, tree.data);
      }

      if (domain.get().initiativeSummaries !== null) {
        const list = await api.get<InitiativeSummary[]>("/initiatives");
        if (list.ok) {
          domain.set((state) => ({ ...state, initiativeSummaries: list.data }));
        }
      }
    })();
  };
}
