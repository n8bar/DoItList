// One Initiative — the deep-link route (m04.01 items 3.2, 3.7, 4.6).
//
// `/app/initiatives/:id` typed into the address bar, pasted from a chat, or
// reloaded must all land here with the Initiative on screen — the header first,
// and the whole task tree under it, drawn from the client's own model.
//
// The header holds its height from the first paint: name, subtitle and progress
// occupy the same block whether they are known, cached or still in flight, so
// the tree underneath does not get pushed down when the read lands. The tree
// holds its own height the same way, through the layout budget.
//
// The tree is READ-ONLY here. Every control is drawn and every key is bound, but
// the writes land with the operation adapter (Arc 3). Nothing is silently dead:
// a control that cannot do its job yet says so (guardrail §6.7).
//
// This is also where the connection seam is exercised — the screen subscribes
// on mount and unsubscribes on unmount, while the connection object itself
// outlives both (guardrail §7.4).

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { InitiativeTree, Member } from "../api/types.ts";
import { COUNT_MIN_WIDTH, reservedHeight } from "../frame/layout_budget.ts";
import { Pane } from "../frame/pane.tsx";
import { Skeleton } from "../frame/skeleton.tsx";
import { Link } from "../router/link.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import { onlineIds, selectionsOf } from "../live/presence_model.ts";
import type { DomainState } from "../state/domain.ts";
import { members as membersOf, presence as presenceOf, putMembers, putTree } from "../state/domain.ts";
import type { PreferencesState } from "../state/preferences.ts";
import type { InitiativeHeader, TreeModel } from "../tree/model.ts";
import { fromSnapshot } from "../tree/model.ts";
import { applyDelta, deltaFromSnapshot } from "../tree/delta.ts";
import { TaskDetails } from "../tree/details.tsx";
import { permissionsFor } from "../tree/permissions.ts";
import { firstUrlWrite, searchWithTask, taskParam } from "../tree/reveal_model.ts";
import type { RowPresence } from "../tree/row_model.ts";
import { memberIndex } from "../tree/row_model.ts";
import { Tree } from "../tree/tree.tsx";
import { ShortcutsOverlay } from "../tree/shortcuts.tsx";
import { useTree } from "../tree/use_tree.ts";
import { UNUSABLE_TREE_MESSAGE, UNUSABLE_TREE_NOTICE } from "../tree/validate.ts";
import type { UiState } from "../state/ui.ts";
import { pushNotice, selectTask } from "../state/ui.ts";
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
        //
        // A refetch goes through the delta rather than replacing the model
        // wholesale, so what the read no longer holds is *removed* rather than
        // merely absent — the set Arc 3's echo cleanup needs, and the only path
        // canonical records are allowed to enter the model by (item 1.5.1).
        const previous = stores.domain.get().trees[id];
        const next =
          previous === undefined
            ? fromSnapshot(data)
            : applyDelta(previous, deltaFromSnapshot(data, previous)).model;
        putTree(stores.domain, next);
        // Same path as the store write, so a tree the guard rejected is never
        // the one that gets cached.
        cache.cacheTree(next);
      },
      [cache, id, stores.domain],
    ),
    // Two reads in a row that could not be a tree. The screen stays on its own
    // error with Try again, and a notice says so, rather than the user staring
    // at a header that will never get a tree (item 1.6.2).
    onUnusable: useCallback(() => {
      pushNotice(stores.ui, {
        kind: "error",
        title: "This Initiative could not be shown",
        message: UNUSABLE_TREE_NOTICE,
      });
      return UNUSABLE_TREE_MESSAGE;
    }, [stores.ui]),
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

      {model === undefined ? (
        // The tree's space, held open before there is a tree, so the Back link
        // and everything under it do not jump when the read lands (§1.1).
        <Skeleton region="initiative-tree" id="initiative-tree-skeleton" />
      ) : (
        <TreeSection id={id} model={model} />
      )}

      <p className="mt-6 text-sm text-zinc-500 dark:text-zinc-400">
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

/** Read-only for now: every write the tree can ask for gets this back. */
const READ_ONLY_TITLE = "Not yet";
const READ_ONLY_MESSAGE =
  "Editing from this view lands in the next arc. Use the workspace to make changes.";

/** The tree, and everything that is true only once there is a tree. */
function TreeSection({ id, model }: { id: number; model: TreeModel }) {
  const { api, stores, connection, escalate } = useServices();
  const rows = useStoreValue(
    stores.preferences,
    useCallback((state: PreferencesState) => state.rows, []),
  );
  const selectedId = useStoreValue(
    stores.ui,
    useCallback((state: UiState) => state.selectedTaskId, []),
  );
  const select = useCallback(
    (taskId: number | null) => selectTask(stores.ui, taskId),
    [stores.ui],
  );
  const memberList = useStoreValue(
    stores.domain,
    useCallback((state: DomainState) => membersOf(state, id), [id]),
  );

  // Who the Initiative's members are — the tree needs them to name an assignee
  // and to draw a co-assignee's avatar. A separate read, because the tree read
  // carries ids, not people.
  useResource<Member[]>({
    key: `members:${id}`,
    loaded: memberList.length > 0,
    read: () => api.get<Member[]>(`/initiatives/${id}/members`),
    onData: useCallback(
      (data: Member[]) => putMembers(stores.domain, id, data),
      [id, stores.domain],
    ),
    escalate,
  });

  const members = useMemo(() => memberIndex(memberList), [memberList]);

  // Who else is here and what they have selected (item 3.4.2). Read from the
  // store the channel writes; the row badges and the online dots are painted
  // from this and nothing else, so presence changes re-render only the rows
  // whose badges changed.
  const me = useStoreValue(
    stores.domain,
    useCallback((state: DomainState) => state.user?.id ?? null, []),
  );
  const presenceState = useStoreValue(
    stores.domain,
    useCallback((state: DomainState) => presenceOf(state, id), [id]),
  );
  const presence = useMemo<RowPresence>(
    () => ({ selections: selectionsOf(presenceState, me), online: onlineIds(presenceState) }),
    [presenceState, me],
  );
  // `viewer_plus` is not in the tree read, so the client assumes it is off and
  // a viewer sees no Progress control it cannot use (item 1.2.3).
  const permissions = useMemo(() => permissionsFor(model.header.role), [model.header.role]);

  const notYet = useCallback(() => {
    pushNotice(stores.ui, {
      kind: "info",
      title: READ_ONLY_TITLE,
      message: READ_ONLY_MESSAGE,
    });
  }, [stores.ui]);

  // Read once, off the address bar the screen arrived on.
  const [deepLinkTaskId] = useState(() => taskParam(window.location.search));

  const tree = useTree({
    model,
    initiativeId: id,
    members,
    presence,
    permissions,
    rows,
    selectedId,
    select,
    deepLinkTaskId,
    onIntent: notYet,
    onAdd: notYet,
    onBlocked: useCallback(() => {
      pushNotice(stores.ui, {
        kind: "info",
        title: "That move has nowhere to go",
        message: "This task is already as far that way as it goes.",
      });
    }, [stores.ui]),
    onDragHint: useCallback(() => {
      pushNotice(stores.ui, {
        kind: "info",
        title: "Hold to drag",
        message: "Tap and hold a task's handle to drag it to a different position.",
      });
    }, [stores.ui]),
  });

  // Kept in step without navigating: same history entry, same key, same scroll —
  // only the one parameter we own changes, so a copied link reopens what the
  // user is looking at.
  //
  // The arrival pass is measured against the selection the tree RESOLVED, not
  // against the one that happened to be in the store when this screen mounted —
  // that one can belong to the Initiative the user came from, and comparing
  // against it stripped the link's own `?task=` and put it back a commit later.
  // Usually a link already says what we resolved, and then nothing is written at
  // all.
  const selected = tree.ctx.selectedTaskId;

  // Tell the others what this window has selected — after it has painted,
  // never before (§6.5). Every change goes out, including the one the screen
  // resolved on arrival; leaving clears it. The connection remembers the value,
  // so a channel that joins later, or again, carries it.
  useEffect(() => () => connection.select(id, null), [connection, id]);
  useEffect(() => {
    connection.select(id, selected);
  }, [connection, id, selected]);

  const resolvedSelection = tree.initialSelectedId;
  const written = useRef<number | null>(deepLinkTaskId);
  const arriving = useRef(true);
  useEffect(() => {
    const replace = (search: string): void => {
      window.history.replaceState(window.history.state, "", window.location.pathname + search);
    };

    if (arriving.current) {
      arriving.current = false;
      written.current = resolvedSelection;
      const first = firstUrlWrite(window.location.search, resolvedSelection);
      if (first !== null) replace(first);
      return;
    }

    if (written.current === selected) return;
    written.current = selected;
    replace(searchWithTask(window.location.search, selected));
  }, [resolvedSelection, selected]);

  return (
    <div className="mt-4">
      <Tree
        ctx={tree.ctx}
        addSlot={tree.addSlot}
        addTitle={tree.addTitle}
        onAddTitleChange={tree.onAddTitleChange}
        onAddMove={tree.onAddMove}
        onAddClose={tree.onAddClose}
        onAdd={tree.onAdd}
      />
      <ShortcutsOverlay open={tree.shortcutsOpen} onClose={tree.closeShortcuts} />
      {/* The Details pane (item 3.4.3): opens with the selection, from the
          model alone — nothing here waits on the network (§6). A selected id
          the model no longer holds (deleted under us) opens nothing. */}
      {selected !== null && model.tasks[selected] !== undefined && (
        <Pane>
          <TaskDetails ctx={tree.ctx} id={selected} onClose={() => select(null)} />
        </Pane>
      )}
    </div>
  );
}
