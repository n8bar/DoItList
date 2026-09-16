// The Initiatives index (m04.01 item 3.2).
//
// The heading and the chrome paint before the read starts; the list arrives
// under a visible loading state and a failure is recoverable in place. Arc 6
// gives this screen its real design — this is the honest minimum that proves
// the route, the store and the read all line up.

import { useCallback } from "react";

import type { InitiativeSummary } from "../api/types.ts";
import { Link } from "../router/link.tsx";
import type { DomainState } from "../state/domain.ts";
import { useStoreValue } from "../state/use_store.ts";
import { useServices } from "../services.tsx";
import { ErrorNote, Heading, Loading } from "./chrome.tsx";
import { useResource } from "./use_resource.ts";

const selectSummaries = (state: DomainState) => state.initiativeSummaries;

export function InitiativesScreen() {
  const { api, stores, escalate } = useServices();
  const summaries = useStoreValue(stores.domain, selectSummaries);

  const resource = useResource<InitiativeSummary[]>({
    key: "initiatives",
    loaded: summaries !== null,
    read: () => api.get<InitiativeSummary[]>("/initiatives"),
    onData: useCallback(
      (data: InitiativeSummary[]) => {
        stores.domain.set((state) => ({ ...state, initiativeSummaries: data }));
      },
      [stores.domain],
    ),
    escalate,
  });

  return (
    <section aria-labelledby="route-heading">
      <Heading>Initiatives</Heading>

      {resource.status === "loading" && <Loading>Loading your Initiatives…</Loading>}
      {resource.status === "error" && (
        <ErrorNote message={resource.message} onRetry={resource.reload} />
      )}

      {summaries !== null && summaries.length === 0 && resource.status === "ready" && (
        <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
          You don’t have any Initiatives yet.
        </p>
      )}

      {summaries !== null && summaries.length > 0 && (
        <ul id="initiatives-list" className="mt-4 divide-y divide-zinc-200 dark:divide-zinc-800">
          {summaries.map((initiative) => (
            <li key={initiative.id} className="py-2">
              <Link
                id={`initiative-link-${initiative.id}`}
                to={`/app/initiatives/${initiative.id}`}
                className="flex items-baseline gap-3 rounded-md px-1 py-1 text-sm transition-colors hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                <span className="font-medium text-zinc-900 dark:text-zinc-100">
                  {initiative.name}
                </span>
                {initiative.subtitle && (
                  <span className="truncate text-zinc-500 dark:text-zinc-400">
                    {initiative.subtitle}
                  </span>
                )}
                <span className="ml-auto tabular-nums text-zinc-500 dark:text-zinc-400">
                  {initiative.progress}%
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
