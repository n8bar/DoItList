// The Initiatives index (m04.02 items 4.1–4.3; m04.01 items 3.2, 4.1, 4.6).
//
// The M02 page, built against its LiveView template
// (`InitiativeWorkspaceLive` index branch): the same header, Sort control and
// card, with the same classes and copy. The rules — order, dates, badge
// colours, the create request — are in `initiatives_model.ts`; this file draws.
//
// The heading and the frame paint before the read starts; the list arrives in
// space that was already reserved for it (`layout_budget`), so nothing on the
// page moves when it lands. A failure is recoverable in place.
//
// Dragging a card's handle reorders the list (4.4): the card lands the moment
// it is dropped, the sort becomes Manual, and `update initiative {position}`
// follows; a refusal puts the old order back and says so.
//
// The Archived and Trash drawer (4.5) sits fixed at the foot of the page, from
// its own read (`/initiatives/archive`) that never holds up the list. Restore
// and Unhide move the row at once — out of the drawer and onto the index —
// and post `update initiative {state}`; a refusal puts it back and says so.
// Live changes (4.6) never touch this file: the sync module patches rows in
// the domain store this screen already reads, and a return to the page asks
// it to revalidate the list behind what is already drawn — no skeleton.

import type { CSSProperties, FormEvent } from "react";
import { useCallback, useEffect, useRef, useState } from "react";

import type {
  ArchivedInitiative,
  InitiativeArchive,
  InitiativeSummary,
  TrashedInitiative,
} from "../api/types.ts";
import { actionClass } from "../frame/button_styles.ts";
import { LIST_ROW_HEIGHT } from "../frame/layout_budget.ts";
import { Link } from "../router/link.tsx";
import { ROUTE_HEADING_ID, useRouter } from "../router/router.tsx";
import type { DomainState } from "../state/domain.ts";
import { pushNotice } from "../state/ui.ts";
import { useStoreValue } from "../state/use_store.ts";
import { browserKeyValueStore } from "../storage/last_user.ts";
import { useServices } from "../services.tsx";
import { InlineError, Skeleton } from "../ui/feedback.tsx";
import { TextArea, TextInput } from "../ui/form.tsx";
import { Icon } from "../ui/icon.tsx";
import { useForm } from "../ui/use_form.ts";
import { Heading } from "./chrome.tsx";
import { useInitiativeDrag } from "./initiative_drag.tsx";
import type { InitiativeDrop } from "./initiative_drag.tsx";
import type {
  ArchiveAction,
  IndexSortMode,
  IndexSortState,
  NewInitiativeValues,
} from "./initiatives_model.ts";
import {
  SORT_OPTIONS,
  applyOrder,
  archiveDrawerTitle,
  archiveHasRows,
  archiveStep,
  archivedRowActions,
  createdInitiative,
  descriptionText,
  droppedOrder,
  hasHidden,
  isSortMode,
  newInitiativeRequest,
  percentText,
  positionRequest,
  progressValue,
  readSortState,
  revertOrder,
  reversed,
  roleBadgeClass,
  sortInitiatives,
  stateRequest,
  storedOrder,
  subtitleText,
  summaryForCreated,
  trashedRowActions,
  trashedText,
  updatedText,
  visibleArchived,
  withJoined,
  withMode,
  withReverse,
  withoutJoined,
  writeSortState,
} from "./initiatives_model.ts";
import { useResource } from "./use_resource.ts";

const selectSummaries = (state: DomainState) => state.initiativeSummaries;
const selectArchive = (state: DomainState) => state.initiativeArchive;

/** The sort choice, remembered in this browser (see `initiatives_model.ts`). */
function useSortState(): [IndexSortState, (next: IndexSortState) => void] {
  const [state, setState] = useState<IndexSortState>(() => readSortState(browserKeyValueStore()));
  const update = useCallback((next: IndexSortState) => {
    setState(next);
    writeSortState(browserKeyValueStore(), next);
  }, []);
  return [state, update];
}

export function InitiativesScreen() {
  const { api, stores, sync, escalate } = useServices();
  const summaries = useStoreValue(stores.domain, selectSummaries);
  const archive = useStoreValue(stores.domain, selectArchive);
  const [sort, setSort] = useSortState();
  const [creating, setCreating] = useState(false);

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

  // A list already held renders at once; the server's version is fetched
  // behind it and only the rows that differ change (4.6). Once, on arrival.
  const heldOnArrival = useRef(summaries !== null);
  useEffect(() => {
    if (heldOnArrival.current) sync.revalidateList();
  }, [sync]);

  // The drawer's own read. It is secondary: a failure here shows no drawer
  // and never stands between the user and the list, so nothing escalates.
  useResource<InitiativeArchive>({
    key: "initiatives-archive",
    loaded: archive !== null,
    read: () => api.get<InitiativeArchive>("/initiatives/archive"),
    onData: useCallback(
      (data: InitiativeArchive) => {
        stores.domain.set((state) => ({ ...state, initiativeArchive: data }));
      },
      [stores.domain],
    ),
    escalate: () => false,
  });

  const count = summaries === null ? 0 : summaries.length;
  const sorted = summaries === null ? [] : sortInitiatives(summaries, sort);

  // A drop reads the sort as it is at that moment, not as it was when the
  // gesture was bound.
  const sortRef = useRef(sort);
  sortRef.current = sort;
  const listRef = useRef<HTMLDivElement | null>(null);

  const onDrop = useCallback(
    (drop: InitiativeDrop) => {
      const prior = stores.domain.get().initiativeSummaries ?? [];
      const shown = sortInitiatives(prior, sortRef.current).map((row) => row.id);
      const next = droppedOrder(shown, drop.sourceId, drop.targetId, drop.side);
      if (next === null) return;

      // A drop lands the list in Manual, as the hook's does.
      const manual = withMode(sortRef.current, "manual");
      const order = storedOrder(next, manual);
      // The card is where it was dropped before the write goes out (§6.2).
      stores.domain.set((state) => ({
        ...state,
        initiativeSummaries: applyOrder(state.initiativeSummaries ?? [], order),
      }));
      setSort(manual);

      // One key per drop: a retry of this write replays, never re-applies.
      void api
        .post<unknown>("/operations", positionRequest(drop.sourceId, order.indexOf(drop.sourceId)), {
          "idempotency-key": crypto.randomUUID(),
        })
        .then((result) => {
          if (result.ok) return;
          // Honest revert: the order the server still has, and why.
          stores.domain.set((state) => ({
            ...state,
            initiativeSummaries: revertOrder(state.initiativeSummaries ?? [], prior),
          }));
          pushNotice(stores.ui, {
            kind: "error",
            message: `Could not save the new order. ${result.error.message}`,
          });
        });
    },
    [api, stores, setSort],
  );
  useInitiativeDrag(listRef, count > 0, onDrop);

  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3 mb-6">
        <div>
          <Heading className="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">
            My Initiatives
          </Heading>
          <p className="text-sm text-zinc-500 dark:text-zinc-400">
            An Initiative holds multiple Lists. Each List is a tree of nested tasks.
          </p>
        </div>
        <button
          type="button"
          id="new-initiative-toggle"
          aria-expanded={creating}
          aria-controls="new-initiative"
          onClick={() => setCreating((open) => !open)}
          className="w-fit self-center inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
        >
          <Icon name="plus" className="w-4 h-4" />
          <span>New Initiative</span>
        </button>
      </div>

      {/* Client-toggled, like the template's <details>: nothing between the
          user and typing (§6.5). */}
      {creating && (
        <NewInitiativeForm
          onClose={() => setCreating(false)}
          onCreated={(summary) => {
            stores.domain.set((state) => ({
              ...state,
              initiativeSummaries: [summary, ...(state.initiativeSummaries ?? [])],
            }));
            setCreating(false);
          }}
        />
      )}

      {/* The skeleton is for having nothing to show. A revisit that already has
          the list keeps showing it while the refresh runs — replacing real rows
          with grey ones would be a step backwards for the user. */}
      {resource.status === "loading" && summaries === null && (
        <Skeleton region="initiatives-list" id="initiatives-skeleton" />
      )}
      {resource.status === "error" && (
        <InlineError message={resource.message} onRetry={resource.reload} />
      )}

      {count > 0 && <SortControl state={sort} onChange={setSort} />}

      {count > 0 && (
        <div id="initiatives" ref={listRef} className="space-y-2">
          {sorted.map((initiative) => (
            <Card key={initiative.id} initiative={initiative} />
          ))}
        </div>
      )}

      {summaries !== null && count === 0 && resource.status === "ready" && (
        <p id="initiatives-empty" className="text-zinc-500 dark:text-zinc-400 mt-4">
          No initiatives yet. Create one to get started.
        </p>
      )}

      {archiveHasRows(archive) && <ArchiveDrawer archive={archive} />}
    </section>
  );
}

// --- Archived + Trash ------------------------------------------------------
//
// The LiveView's `<details id="archived">`, structure and copy intact. Open or
// closed and the two Show boxes are the viewer's business alone, so they are
// React state; the rows are what the server said, in the domain store.

const RESTORE_CLASS =
  "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30";
const UNHIDE_CLASS =
  "inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-semibold border border-zinc-400 dark:border-zinc-600 text-zinc-600 dark:text-zinc-300 hover:bg-zinc-100 dark:hover:bg-zinc-800";
const ROW_CLASS =
  "flex flex-col gap-1 rounded border border-zinc-200 dark:border-zinc-800 bg-zinc-50/60 dark:bg-zinc-900 px-3 py-2";

function ArchiveDrawer({ archive }: { archive: InitiativeArchive }) {
  const { api, stores } = useServices();
  const [open, setOpen] = useState(false);
  const [showHidden, setShowHidden] = useState(false);
  const [showTrash, setShowTrash] = useState(false);

  const act = useCallback(
    (bucket: "archived" | "trashed", id: number, action: ArchiveAction) => {
      const domain = stores.domain.get();
      const before = domain.initiativeArchive;
      if (before === null) return;
      const step = archiveStep(before, bucket, id, action);
      if (step === null) return;

      // The row moves the moment the button is pressed (§6.2).
      stores.domain.set((state) => ({
        ...state,
        initiativeArchive: step.archive,
        initiativeSummaries:
          step.joined === null
            ? state.initiativeSummaries
            : withJoined(state.initiativeSummaries ?? [], step.joined),
      }));

      void api
        .post<unknown>("/operations", stateRequest(id, step.state), {
          "idempotency-key": crypto.randomUUID(),
        })
        .then((result) => {
          if (result.ok) return;
          // Honest revert: the row goes back where the server still has it.
          stores.domain.set((state) => ({
            ...state,
            initiativeArchive: before,
            initiativeSummaries:
              step.joined === null
                ? state.initiativeSummaries
                : withoutJoined(state.initiativeSummaries ?? [], id),
          }));
          const verb = action === "unhide" ? "unhide" : "restore";
          pushNotice(stores.ui, {
            kind: "error",
            message: `Could not ${verb} that Initiative. ${result.error.message}`,
          });
        });
    },
    [api, stores],
  );

  const title = archiveDrawerTitle(archive, showHidden);
  const shown = visibleArchived(archive.archived, showHidden);

  return (
    <details
      id="archived"
      open={open}
      onToggle={(event) => setOpen((event.currentTarget as HTMLDetailsElement).open)}
      aria-label={title}
      className="group fixed bottom-0 z-30 border-t border-zinc-200 dark:border-zinc-800 bg-white/95 dark:bg-zinc-900/95 backdrop-blur supports-[backdrop-filter]:bg-white/80 dark:supports-[backdrop-filter]:bg-zinc-900/80 shadow-[0_-1px_3px_rgba(0,0,0,0.06)] 3xl:rounded-t-lg 3xl:border-x 3xl:shadow-[0_-1px_3px_rgba(0,0,0,0.1)]"
    >
      <summary className="flex cursor-pointer list-none select-none items-center gap-2 px-4 sm:px-6 3xl:px-3 py-2.5 text-sm font-semibold text-zinc-600 dark:text-zinc-300 [&::-webkit-details-marker]:hidden hover:bg-zinc-50 dark:hover:bg-zinc-800/50">
        {archive.archived.length > 0 && (
          <>
            <Icon name="archive-box" className="w-4 h-4 flex-none" />
            <span>Archived ({shown.length})</span>
          </>
        )}
        {archive.archived.length > 0 && archive.trashed.length > 0 && (
          <span className="text-zinc-400 dark:text-zinc-500">·</span>
        )}
        {archive.trashed.length > 0 && (
          <>
            <Icon name="trash" className="w-4 h-4 flex-none" />
            <span>Trash ({archive.trashed.length})</span>
          </>
        )}
        <Icon
          name="chevron-up"
          className="ml-auto w-4 h-4 flex-none transition-transform group-open:rotate-180"
        />
      </summary>
      <div className="px-4 sm:px-6 3xl:px-3 pb-3">
        <div className="flex items-center justify-end gap-2">
          {hasHidden(archive.archived) && (
            <label className="flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400 select-none">
              <input
                type="checkbox"
                id="show-hidden"
                checked={showHidden}
                onChange={(event) => setShowHidden(event.target.checked)}
                className="checkbox checkbox-xs"
              />{" "}
              Show hidden
            </label>
          )}
          {archive.trashed.length > 0 && (
            <label className="flex items-center gap-1.5 text-xs text-zinc-500 dark:text-zinc-400 select-none">
              <input
                type="checkbox"
                id="show-trash"
                checked={showTrash}
                onChange={(event) => setShowTrash(event.target.checked)}
                className="checkbox checkbox-xs"
              />{" "}
              Show trash
            </label>
          )}
        </div>
        <ul className="mt-2 space-y-1 max-h-[40vh] overflow-y-auto">
          {shown.map((row) => (
            <ArchivedRow key={row.id} row={row} onAct={(action) => act("archived", row.id, action)} />
          ))}
        </ul>
        {archive.trashed.length > 0 && showTrash && (
          <div className="mt-4 pt-3 border-t border-zinc-200 dark:border-zinc-800">
            <h3 className="flex items-center gap-1.5 text-xs font-semibold text-zinc-500 dark:text-zinc-400 uppercase tracking-wide">
              <Icon name="trash" className="w-3.5 h-3.5" /> Trash
              <span className="font-normal normal-case text-zinc-400 dark:text-zinc-500">
                · auto-deletes after {archive.retention_days} days
              </span>
            </h3>
            <ul className="mt-2 space-y-1 max-h-[40vh] overflow-y-auto">
              {archive.trashed.map((row) => (
                <TrashedRow key={row.id} row={row} onAct={(action) => act("trashed", row.id, action)} />
              ))}
            </ul>
          </div>
        )}
      </div>
    </details>
  );
}

function ArchivedRow({
  row,
  onAct,
}: {
  row: ArchivedInitiative;
  onAct: (action: ArchiveAction) => void;
}) {
  const actions = archivedRowActions(row);
  return (
    <li id={`archived-${row.id}`} className={ROW_CLASS}>
      <span className="flex items-center gap-2 min-w-0 text-sm text-zinc-600 dark:text-zinc-300">
        <GroveIcon className="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
        <span className="truncate">{row.name}</span>
        {row.hidden && !row.archived && (
          <span className="text-[10px] uppercase tracking-wide font-semibold px-1.5 py-0.5 rounded bg-zinc-200 text-zinc-600 dark:bg-zinc-700 dark:text-zinc-300">
            hidden
          </span>
        )}
      </span>
      <div className="flex items-center justify-end gap-2">
        <span className="flex items-center gap-1 flex-none">
          {actions.includes("restore") && (
            <button
              type="button"
              id={`archived-${row.id}-restore`}
              onClick={() => onAct("restore")}
              className={RESTORE_CLASS}
            >
              <Icon name="arrow-uturn-left" className="w-3.5 h-3.5" /> Restore
            </button>
          )}
          {actions.includes("unhide") && (
            <button
              type="button"
              id={`archived-${row.id}-unhide`}
              onClick={() => onAct("unhide")}
              className={UNHIDE_CLASS}
            >
              <Icon name="eye" className="w-3.5 h-3.5" /> Unhide
            </button>
          )}
        </span>
      </div>
    </li>
  );
}

function TrashedRow({
  row,
  onAct,
}: {
  row: TrashedInitiative;
  onAct: (action: ArchiveAction) => void;
}) {
  const actions = trashedRowActions(row);
  return (
    <li id={`trashed-${row.id}`} className={ROW_CLASS}>
      <span className="flex items-center gap-2 min-w-0 text-sm text-zinc-600 dark:text-zinc-300">
        <GroveIcon className="w-4 h-4 text-zinc-400 dark:text-zinc-500" />
        <span className="truncate">{row.name}</span>
      </span>
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs text-zinc-400 dark:text-zinc-500 whitespace-nowrap">
          {trashedText(row.trashed_at)}
        </span>
        <span className="flex items-center gap-1 flex-none">
          {actions.includes("restore") && (
            <button
              type="button"
              id={`trashed-${row.id}-restore`}
              onClick={() => onAct("restore")}
              className={RESTORE_CLASS}
            >
              <Icon name="arrow-uturn-left" className="w-3.5 h-3.5" /> Restore
            </button>
          )}
        </span>
      </div>
    </li>
  );
}

// --- Sort ------------------------------------------------------------------

function SortControl({
  state,
  onChange,
}: {
  state: IndexSortState;
  onChange: (next: IndexSortState) => void;
}) {
  return (
    <form
      id="initiative-sort"
      onSubmit={(event: FormEvent) => event.preventDefault()}
      className="flex items-center justify-end gap-2 mb-3 text-zinc-600 dark:text-zinc-300"
    >
      <label htmlFor="initiative-sort-mode" className="text-xs">
        Sort
      </label>
      <select
        id="initiative-sort-mode"
        name="mode"
        value={state.mode}
        onChange={(event) => {
          const mode: IndexSortMode = isSortMode(event.target.value) ? event.target.value : "";
          onChange(withMode(state, mode));
        }}
        className="select select-bordered select-sm"
      >
        {SORT_OPTIONS.map((option) => (
          <option key={option.value} value={option.value}>
            {option.label}
          </option>
        ))}
      </select>
      <label className="flex items-center gap-1 text-xs select-none">
        <input
          type="checkbox"
          name="reverse"
          value="true"
          checked={reversed(state)}
          onChange={(event) => onChange(withReverse(state, event.target.checked))}
          className="checkbox checkbox-xs"
        />{" "}
        Reverse
      </label>
    </form>
  );
}

// --- Card ------------------------------------------------------------------

function Card({ initiative }: { initiative: InitiativeSummary }) {
  const progress = progressValue(initiative.progress);
  const subtitle = subtitleText(initiative);
  const description = descriptionText(initiative);

  return (
    <div
      id={`initiatives-${initiative.id}`}
      data-initiative-id={initiative.id}
      className="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 hover:shadow-sm transition motion-reduce:transition-none"
      // The skeleton row renders the same number, from the same constant —
      // that is what makes the swap free of movement (m04.01 item 4.6).
      style={{ minHeight: `${LIST_ROW_HEIGHT}px` }}
    >
      <Link
        id={`initiative-link-${initiative.id}`}
        to={`/app/initiatives/${initiative.id}`}
        draggable={false}
        className="block p-4"
      >
        <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-1 sm:gap-3">
          <span className="font-medium text-zinc-800 dark:text-zinc-100 inline-flex items-center gap-2 min-w-0">
            {/* The handle sits inside the card's link; on touch, a long-press
                would otherwise open the link's callout and cancel the drag. */}
            <span
              id={`init-drag-${initiative.id}`}
              data-drag-handle=""
              aria-hidden="true"
              title="Drag to reorder"
              onContextMenu={(event) => event.preventDefault()}
              style={{ WebkitTouchCallout: "none" } as CSSProperties}
              className="flex-none inline-flex items-center gap-0.5 text-emerald-600 dark:text-emerald-400 cursor-grab active:cursor-grabbing touch-none select-none"
            >
              <Icon name="ellipsis-vertical" className="w-3 h-3 text-zinc-600 dark:text-zinc-500" />
              <GroveIcon className="w-5 h-5" />
              <Icon name="ellipsis-vertical" className="w-3 h-3 text-zinc-600 dark:text-zinc-500" />
            </span>
            <span className="truncate">{initiative.name}</span>
          </span>
          <div className="flex items-center gap-2 flex-none">
            <span
              className={`text-[10px] uppercase tracking-wide font-semibold px-1.5 py-0.5 rounded ${roleBadgeClass(initiative.role)}`}
              title={`Your role: ${initiative.role}`}
            >
              {initiative.role}
            </span>
            <span className="text-xs text-zinc-500 dark:text-zinc-400">
              {updatedText(initiative.updated_at)}
            </span>
          </div>
        </div>
        {subtitle !== null && (
          <p
            data-initiative-card-field=""
            className="mt-1 text-sm text-zinc-600 dark:text-zinc-300 line-clamp-1"
          >
            {subtitle}
          </p>
        )}
        {description !== null && (
          <p
            data-initiative-card-field=""
            className="mt-1 text-sm text-zinc-500 dark:text-zinc-400 line-clamp-2"
          >
            {description}
          </p>
        )}

        <div
          className="relative mt-2 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden"
          role="progressbar"
          aria-valuenow={progress}
          aria-valuemin={0}
          aria-valuemax={100}
          aria-label={`Progress: ${percentText(progress)}`}
          style={{ "--progress": `${progress}%` } as CSSProperties}
        >
          <div
            className="absolute inset-y-0 left-0 bg-emerald-400 rounded-full"
            style={{ width: "var(--progress)" }}
          />
          <span className="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
            {percentText(progress)}
          </span>
        </div>
      </Link>
    </div>
  );
}

/** `botanical_icon(:grove)`, path for path — the Initiative's own glyph. */
function GroveIcon({ className }: { className: string }) {
  return (
    <svg
      className={className}
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth={2}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
    >
      <path d="M10 10v.2A3 3 0 0 1 8.9 16H5a3 3 0 0 1-1-5.8V10a3 3 0 0 1 6 0Z" />
      <path d="M7 16v6" />
      <path d="M13 19v3" />
      <path d="M12 19h8.3a1 1 0 0 0 .7-1.7L18 14h.3a1 1 0 0 0 .7-1.7L16 9h.2a1 1 0 0 0 .8-1.7L13 3l-1.4 1.5" />
    </svg>
  );
}

// --- New Initiative --------------------------------------------------------

const FORM_ID = "new-initiative-form";

function NewInitiativeForm({
  onClose,
  onCreated,
}: {
  onClose: () => void;
  onCreated: (summary: InitiativeSummary) => void;
}) {
  const { api, stores } = useServices();
  const { navigate } = useRouter();

  const form = useForm<NewInitiativeValues, unknown>({
    initial: { name: "", description: "" },
    submit: (values) => api.post<unknown>("/operations", newInitiativeRequest(values)),
    onSuccess: (data, values) => {
      const created = createdInitiative(data);
      if (created === null) {
        // The write landed but the reply is not one this client can read. The
        // next read of the list will show the row; say so rather than nothing.
        pushNotice(stores.ui, { kind: "info", message: "Initiative created." });
        onClose();
        return;
      }
      onCreated(summaryForCreated(created, values, new Date().toISOString()));
      navigate(`/app/initiatives/${created.id}`);
    },
  });

  // The name field takes focus the moment the form opens, as the pointer would
  // land there next anyway.
  useEffect(() => {
    document.getElementById(`${FORM_ID}-name`)?.focus();
  }, []);

  return (
    <div id="new-initiative" className="mb-6">
      <div className="rounded border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4">
        <form id={FORM_ID} onSubmit={form.onSubmit} className="space-y-3">
          <TextInput
            formId={FORM_ID}
            name="name"
            label="Name"
            required
            value={form.values.name}
            onChange={(value) => form.setValue("name", value)}
            error={form.errors["name"] ?? null}
          />
          <TextArea
            formId={FORM_ID}
            name="description"
            label="Description (optional)"
            value={form.values.description}
            onChange={(value) => form.setValue("description", value)}
            error={form.errors["description"] ?? null}
          />
          {form.formError !== null && (
            <p role="alert" className="text-sm text-red-700 dark:text-red-300">
              {form.formError}
            </p>
          )}
          <div className="flex justify-end gap-2">
            <button
              type="button"
              id={`${FORM_ID}-cancel`}
              onClick={onClose}
              className="px-3 py-1.5 rounded border border-zinc-300 dark:border-zinc-700 text-sm text-zinc-700 dark:text-zinc-200 hover:bg-zinc-50 dark:hover:bg-zinc-800"
            >
              Cancel
            </button>
            {/* The press is acknowledged in the same box it was made in: the
                label latches to "Creating…" (§6.7), width held. */}
            <button
              type="submit"
              id={`${FORM_ID}-submit`}
              disabled={form.busy}
              aria-busy={form.busy}
              className={`${actionClass({ variant: "primary", ...(form.busy ? { disabled: true } : {}) })} min-w-36`}
            >
              {form.busy && <Icon name="arrow-path" spin />}
              {form.busy ? "Creating…" : "Create initiative"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
