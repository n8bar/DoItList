// The Initiatives index (m04.01 items 3.2, 4.1, 4.6).
//
// The heading and the frame paint before the read starts; the list arrives in
// space that was already reserved for it (`layout_budget`), so nothing on the
// page moves when it lands. A failure is recoverable in place.
//
// Each row is a navigation action that looks like one (item 4.4): a real link,
// with a visible boundary, a name, the user's role and rolled-up progress. Arc
// 6 gives the screen its full design — the shape is the product's, though, so
// the list reads the same here as it does in the rail.

import { useCallback } from "react";

import type { InitiativeSummary, Role } from "../api/types.ts";
import { controlClass } from "../frame/button_styles.ts";
import { COUNT_MIN_WIDTH, LIST_ROW_HEIGHT } from "../frame/layout_budget.ts";
import { Skeleton } from "../frame/skeleton.tsx";
import { Link } from "../router/link.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import type { DomainState } from "../state/domain.ts";
import { useStoreValue } from "../state/use_store.ts";
import { useServices } from "../services.tsx";
import { ErrorNote, Heading } from "./chrome.tsx";
import { useResource } from "./use_resource.ts";

const selectSummaries = (state: DomainState) => state.initiativeSummaries;

/** Mirrors the LiveView rail's role badge — same words, same weight. */
const ROLE_BADGE: Record<Role, string> = {
  owner: "border-emerald-300 bg-emerald-50 text-emerald-800 dark:border-emerald-700 dark:bg-emerald-900/40 dark:text-emerald-200",
  editor: "border-sky-300 bg-sky-50 text-sky-800 dark:border-sky-700 dark:bg-sky-900/40 dark:text-sky-200",
  viewer: "border-zinc-300 bg-zinc-100 text-zinc-700 dark:border-zinc-600 dark:bg-zinc-800 dark:text-zinc-300",
};

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
    <section aria-labelledby={ROUTE_HEADING_ID}>
      <Heading>Initiatives</Heading>

      {/* The skeleton is for having nothing to show. A revisit that already has
          the list keeps showing it while the refresh runs — replacing real rows
          with grey ones would be a step backwards for the user. */}
      {resource.status === "loading" && summaries === null && (
        <Skeleton region="initiatives-list" id="initiatives-skeleton" />
      )}
      {resource.status === "error" && (
        <ErrorNote message={resource.message} onRetry={resource.reload} />
      )}

      {summaries !== null && summaries.length === 0 && resource.status === "ready" && (
        <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
          You don’t have any Initiatives yet.
        </p>
      )}

      {summaries !== null && summaries.length > 0 && (
        <ul id="initiatives-list" className="mt-4 flex flex-col gap-2">
          {summaries.map((initiative) => (
            <li key={initiative.id}>
              <Link
                id={`initiative-link-${initiative.id}`}
                to={`/app/initiatives/${initiative.id}`}
                className={controlClass({ stack: true })}
                // The skeleton row renders the same number, from the same
                // constant — that is what makes the swap free of movement.
                style={{ minHeight: `${LIST_ROW_HEIGHT}px` }}
              >
                <span className="flex min-w-0 items-center gap-2">
                  <span className="min-w-0 flex-1 truncate text-zinc-900 dark:text-zinc-100">
                    {initiative.name}
                  </span>
                  {initiative.subtitle !== null && initiative.subtitle !== "" && (
                    <span className="hidden min-w-0 flex-1 truncate font-normal text-zinc-500 sm:inline dark:text-zinc-400">
                      {initiative.subtitle}
                    </span>
                  )}
                  <span
                    className={`flex-none rounded border px-1.5 py-0.5 text-[10px] uppercase tracking-wide ${ROLE_BADGE[initiative.role]}`}
                  >
                    {initiative.role}
                  </span>
                  {/* Reserved width: a percentage arriving must not shove the
                      role badge sideways (item 4.6). */}
                  <span
                    className="flex-none text-right tabular-nums text-zinc-600 dark:text-zinc-300"
                    style={{ minWidth: COUNT_MIN_WIDTH }}
                  >
                    {initiative.progress}%
                  </span>
                </span>
                <span
                  className="h-1 w-full overflow-hidden rounded-full bg-zinc-200 dark:bg-zinc-700"
                  role="progressbar"
                  aria-valuenow={initiative.progress}
                  aria-valuemin={0}
                  aria-valuemax={100}
                  aria-label={`${initiative.name} progress`}
                >
                  <span
                    className="block h-full bg-emerald-500"
                    style={{ width: `${initiative.progress}%` }}
                  />
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
