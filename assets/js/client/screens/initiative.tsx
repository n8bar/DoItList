// One Initiative — the deep-link route (m04.01 items 3.2, 3.7).
//
// `/app/initiatives/:id` typed into the address bar, pasted from a chat, or
// reloaded must all land here with the Initiative on screen. Only the header
// (name, subtitle, rolled-up progress) is rendered: Arc 2 owns the task tree.
//
// This is also where the connection seam is exercised — the screen subscribes
// on mount and unsubscribes on unmount, while the connection object itself
// outlives both (guardrail §7.4).

import { useCallback, useEffect } from "react";

import type { InitiativeTree } from "../api/types.ts";
import { Link } from "../router/link.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import type { DomainState } from "../state/domain.ts";
import { putInitiativeTree } from "../state/domain.ts";
import { useStoreValue } from "../state/use_store.ts";
import { useServices } from "../services.tsx";
import { ErrorNote, Heading, Loading } from "./chrome.tsx";
import { useResource } from "./use_resource.ts";

export function InitiativeScreen({ id }: { id: number }) {
  const { api, stores, connection, escalate } = useServices();

  const select = useCallback((state: DomainState) => state.initiativeTrees[id], [id]);
  const tree = useStoreValue(stores.domain, select);

  useEffect(() => {
    connection.subscribeInitiative(id);
    return () => connection.unsubscribeInitiative(id);
  }, [connection, id]);

  const resource = useResource<InitiativeTree>({
    key: `initiative:${id}`,
    loaded: tree !== undefined,
    read: () => api.get<InitiativeTree>(`/initiatives/${id}`),
    onData: useCallback(
      (data: InitiativeTree) => putInitiativeTree(stores.domain, data),
      [stores.domain],
    ),
    escalate,
  });

  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      <Heading>{tree?.name ?? "Initiative"}</Heading>

      {tree?.subtitle && (
        <p className="mt-1 text-sm text-zinc-500 dark:text-zinc-400">{tree.subtitle}</p>
      )}

      {tree && (
        <p id="initiative-progress" className="mt-3 text-sm text-zinc-600 dark:text-zinc-300">
          <span className="font-medium tabular-nums text-zinc-900 dark:text-zinc-100">
            {tree.progress}%
          </span>{" "}
          across {tree.unit_count} {tree.unit_count === 1 ? "unit" : "units"}
        </p>
      )}

      {resource.status === "loading" && <Loading>Loading this Initiative…</Loading>}
      {resource.status === "error" && (
        <ErrorNote message={resource.message} onRetry={resource.reload} />
      )}

      <p className="mt-6 text-sm text-zinc-500 dark:text-zinc-400">
        The task tree lands in the next arc.{" "}
        <Link
          id="initiative-back"
          to="/app/initiatives"
          className="underline underline-offset-2 hover:text-zinc-900 dark:hover:text-zinc-100"
        >
          All Initiatives
        </Link>
      </p>
    </section>
  );
}
