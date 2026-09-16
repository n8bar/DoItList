// One Initiative — the deep-link route (m04.01 items 3.2, 3.7, 4.6).
//
// `/app/initiatives/:id` typed into the address bar, pasted from a chat, or
// reloaded must all land here with the Initiative on screen. Only the header
// (name, subtitle, rolled-up progress) is rendered: Arc 2 owns the task tree.
//
// The header holds its height from the first paint: name, subtitle and progress
// occupy the same block whether they are known, cached or still in flight, so
// the tree Arc 2 hangs underneath does not get pushed down when the read lands.
//
// This is also where the connection seam is exercised — the screen subscribes
// on mount and unsubscribes on unmount, while the connection object itself
// outlives both (guardrail §7.4).

import { useCallback, useEffect, useState } from "react";

import type { InitiativeTree } from "../api/types.ts";
import { COUNT_MIN_WIDTH, reservedHeight } from "../frame/layout_budget.ts";
import { Link } from "../router/link.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import type { DomainState } from "../state/domain.ts";
import { putTree } from "../state/domain.ts";
import type { InitiativeHeader } from "../tree/model.ts";
import { fromSnapshot } from "../tree/model.ts";
import { useStoreValue } from "../state/use_store.ts";
import { useServices } from "../services.tsx";
import type { InitiativeSnapshot } from "../storage/snapshots.ts";
import { InlineError } from "../ui/feedback.tsx";
import { Heading } from "./chrome.tsx";
import { useResource } from "./use_resource.ts";

export function InitiativeScreen({ id }: { id: number }) {
  const { api, stores, connection, cache, escalate } = useServices();

  const select = useCallback((state: DomainState) => state.trees[id], [id]);
  const model = useStoreValue(stores.domain, select);

  // The last copy this device saved, shown while the live read is in flight so
  // a reload on a slow link has a header instead of a spinner. It is dropped
  // the moment the server answers, and it is never shown as if it were current.
  const [cached, setCached] = useState<InitiativeSnapshot | null>(null);

  useEffect(() => {
    let live = true;
    void cache.readTree(id).then((snapshot) => {
      if (live) setCached(snapshot);
    });
    return () => {
      live = false;
    };
  }, [cache, id]);

  useEffect(() => {
    connection.subscribeInitiative(id);
    return () => connection.unsubscribeInitiative(id);
  }, [connection, id]);

  const resource = useResource<InitiativeTree>({
    key: `initiative:${id}`,
    loaded: model !== undefined,
    read: () => api.get<InitiativeTree>(`/initiatives/${id}`),
    onData: useCallback(
      (data: InitiativeTree) => {
        // The nested read becomes the client's own model here and nowhere else;
        // a snapshot that cannot be a tree throws instead of being half-drawn.
        const next = fromSnapshot(data);
        putTree(stores.domain, next);
        // Same path as the store write, so a tree the guard rejected is never
        // the one that gets cached.
        cache.cacheTree(next);
      },
      [cache, stores.domain],
    ),
    escalate,
  });

  // The server's copy always wins; the cache only fills the gap before it lands.
  const shown: InitiativeHeader | InitiativeSnapshot | null = model?.header ?? cached;
  const fromCache = model === undefined && cached !== null;

  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      {/* The header's space is held open whether or not its content exists. */}
      <div
        id="initiative-header"
        className="flex flex-col justify-center"
        style={{ minHeight: reservedHeight("initiative-header") }}
      >
        <Heading>{shown?.name ?? "Initiative"}</Heading>

        {shown === null ? (
          // Sized line for line against the real header below, so the box does
          // not change height when the read lands (item 4.6).
          <div id="initiative-header-skeleton" role="status" aria-busy="true">
            <span className="sr-only">Loading…</span>
            <div
              aria-hidden="true"
              className="mt-1 h-5 w-48 animate-pulse rounded bg-zinc-100 motion-reduce:animate-none dark:bg-zinc-800"
            />
            <div
              aria-hidden="true"
              className="mt-2 h-5 w-32 animate-pulse rounded bg-zinc-100 motion-reduce:animate-none dark:bg-zinc-800"
            />
          </div>
        ) : (
          <>
            <p className="mt-1 truncate text-sm text-zinc-500 dark:text-zinc-400">
              {shown.subtitle ?? " "}
            </p>
            <p id="initiative-progress" className="mt-2 text-sm text-zinc-600 dark:text-zinc-300">
              <span
                className="inline-block text-right font-medium tabular-nums text-zinc-900 dark:text-zinc-100"
                style={{ minWidth: COUNT_MIN_WIDTH }}
              >
                {shown.progress}%
              </span>{" "}
              across {shown.unit_count} {shown.unit_count === 1 ? "unit" : "units"}
            </p>
          </>
        )}
      </div>

      {fromCache && (
        <p id="initiative-cached" className="mt-2 text-xs text-zinc-500 dark:text-zinc-400">
          The last copy saved on this device, while the current one loads.
        </p>
      )}

      {resource.status === "error" && (
        <InlineError message={resource.message} onRetry={resource.reload} />
      )}

      <p className="mt-6 text-sm text-zinc-500 dark:text-zinc-400">
        The task tree lands in the next arc.{" "}
        <Link
          id="initiative-back"
          to="/app/initiatives"
          className="rounded underline underline-offset-2 hover:text-zinc-900 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 dark:hover:text-zinc-100 dark:focus-visible:ring-emerald-400"
        >
          All Initiatives
        </Link>
      </p>
    </section>
  );
}
