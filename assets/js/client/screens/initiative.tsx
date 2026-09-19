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
// Every write the tree asks for goes out through the operation adapter
// (`tree/adapter.ts`, item 5.1.1): one batch per intent, in order, under an
// idempotency key. The moment a batch is queued its prediction is on screen
// and its rows are pending (item 5.2); the reply's delta — or the write's own
// broadcast, whichever lands first (m04.03 1.4.1) — lands on canonical truth
// and the prediction is dropped; a rejection reverts the tree and is said out
// loud — or, for a pane edit, kept in the field with the reason beside it.
// Canonical truth, the sequence and the predictions live in the Initiative's
// sync session (`live/refresh.ts`), outside React: this screen only keeps the
// marks (pink rows, stand-in keys, a refused edit) that go with them.
//
// This is also where the connection seam is exercised — the screen subscribes
// on mount and unsubscribes on unmount, while the connection object itself
// outlives both (guardrail §7.4).

import type { RefObject } from "react";
import { memo, useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { InitiativeTree, Member } from "../api/types.ts";
import { Pane } from "../frame/pane.tsx";
import { Skeleton } from "../frame/skeleton.tsx";
import { Link } from "../router/link.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import { onlineIds, selectionsOf } from "../live/presence_model.ts";
import type { DomainState } from "../state/domain.ts";
import { members as membersOf, presence as presenceOf, putMembers } from "../state/domain.ts";
import type { PreferencesState } from "../state/preferences.ts";
import type { InitiativeHeader as HeaderRecord, TreeModel } from "../tree/model.ts";
import type { Submission, SubmitResult, TreeWrite } from "../tree/adapter.ts";
import { createAdapter, predictWrite, rejectionMessage, targetOf } from "../tree/adapter.ts";
import { REJECTED_TITLE, historySentence, rejectionSentence, warnRejection } from "../tree/notice_model.ts";
import type { AddRequest } from "../tree/add_form_model.ts";
import { CONFIRM_CLASSES, dialogIdFor, skippable } from "../tree/confirm_model.ts";
import type { EditRejection, TreeIntent } from "../tree/context.ts";
import { TaskDetails } from "../tree/details.tsx";
import { alias } from "../tree/optimistic.ts";
import type { PendingMap } from "../tree/pending_model.ts";
import {
  NO_PENDING,
  begin as beginPending,
  recomputingIds,
  savingIds,
  scopeFor,
  settle,
} from "../tree/pending_model.ts";
import { permissionsFor } from "../tree/permissions.ts";
import { firstUrlWrite, searchWithTask, taskParam } from "../tree/reveal_model.ts";
import { selectionOf } from "../tree/selection_model.ts";
import type { RowPresence } from "../tree/row_model.ts";
import { memberIndex } from "../tree/row_model.ts";
import { createPresenceStore } from "../tree/presence_store.ts";
import type { RowMarks } from "../tree/task_store.ts";
import { createTaskReader } from "../tree/task_store.ts";
import { Tree } from "../tree/tree.tsx";
import { ShortcutsOverlay } from "../tree/shortcuts.tsx";
import type { ConfirmState } from "../tree/use_confirm.ts";
import { useConfirm } from "../tree/use_confirm.ts";
import { useTree } from "../tree/use_tree.ts";
import { UNUSABLE_TREE_MESSAGE, UNUSABLE_TREE_NOTICE } from "../tree/validate.ts";
import { createStore, derive } from "../state/store.ts";
import type { UiState } from "../state/ui.ts";
import { pushNotice, selectTask } from "../state/ui.ts";
import { useStore, useStoreValue } from "../state/use_store.ts";
import { useServices } from "../services.tsx";
import { browserKeyValueStore } from "../storage/last_user.ts";
import type { InitiativeSnapshot } from "../storage/snapshots.ts";
import { ConfirmDialog } from "../ui/dialog.tsx";
import { InlineError } from "../ui/feedback.tsx";
import { InitiativeHeader } from "./initiative_header.tsx";
import type { HeaderFields } from "./initiative_header_model.ts";
import { adoptHeaderReply, headerCounts, headerEdit, revertHeader } from "./initiative_header_model.ts";
import { useResource } from "./use_resource.ts";

export function InitiativeScreen({ id }: { id: number }) {
  const { api, stores, connection, sync, cache, escalate } = useServices();

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
    // The read goes to the Initiative's sync session, which the channel was
    // joined for before the read went out: deltas that arrived meanwhile
    // follow the snapshot in order, and one older than what the session
    // already holds is refused (m04.03 1.4). A snapshot that cannot be a tree
    // throws instead of being half-drawn.
    onData: useCallback((data: InitiativeTree) => sync.install(data), [sync]),
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
  const shown: HeaderRecord | InitiativeSnapshot | null = model?.header ?? cached;
  const fromCache = model === undefined && cached !== null;

  // What the header can do once there is a tree — New List and the
  // click-to-edit writes — is the tree section's, which owns the writes'
  // truth; it hands them up here, where the header is drawn from the first
  // paint on (a cached header has none of them).
  const headerActions = useRef<HeaderActions | null>(null);
  const counts = useMemo(() => (model === undefined ? null : headerCounts(model)), [model]);
  const canEdit = model !== undefined && permissionsFor(model.header.role).canEdit;

  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      {/* The header's space is held open whether or not its content exists. */}
      <InitiativeHeader
        name={shown?.name ?? "Initiative"}
        subtitle={shown?.subtitle ?? null}
        progress={shown?.progress ?? 0}
        counts={counts}
        calc={model?.progressCalc ?? null}
        canEdit={canEdit}
        loading={shown === null}
        {...(model === undefined
          ? {}
          : {
              onAddRoot: () => headerActions.current?.addRoot(),
              onCommit: (fields: HeaderFields) => headerActions.current?.commitHeader(fields),
            })}
      />

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
        <TreeSection id={id} model={model} actions={headerActions} />
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

/** What the header asks of the tree section (item 7.10). */
interface HeaderActions {
  addRoot(): void;
  commitHeader(fields: HeaderFields): void;
}

/**
 * What is true about writes in flight and nowhere else (item 5.2.1): which rows
 * are pending, which added rows keep a stand-in key, and the last refused pane
 * edit. Ephemeral — it lives with the mounted tree and never enters the model.
 * A store rather than React state so it commits in the same pass as the tree
 * store: the pink and the prediction land together, and lift together.
 */
interface InFlightState {
  readonly pending: PendingMap;
  readonly rowKeys: ReadonlyMap<number, number>;
  readonly rejection: EditRejection | null;
  /** The undo or redo in flight, if any — one at a time, its button latched. */
  readonly history: "undo" | "redo" | null;
}

const NOTHING_IN_FLIGHT: InFlightState = {
  pending: NO_PENDING,
  rowKeys: new Map(),
  rejection: null,
  history: null,
};

/** The tree, and everything that is true only once there is a tree. */
/**
 * One dialog per confirm class, under the id the LiveView's modal had. Only
 * the yes control submits; Escape, the backdrop and Cancel drop the write. The
 * delete confirm has no "don't show this again", like the workspace's.
 *
 * Memoized (7.17): the screen re-renders for every selection, and six closed
 * dialogs re-rendering with it were a measurable slice of the click.
 */
const ConfirmDialogs = memo(function ConfirmDialogs({
  open,
  dontAsk,
  setDontAsk,
  proceed,
  cancel,
}: Pick<ConfirmState, "open" | "dontAsk" | "setDontAsk" | "proceed" | "cancel">) {
  return (
    <>
      {CONFIRM_CLASSES.map((confirmClass) => {
        const shown = open !== null && open.confirm.class === confirmClass;
        const current = shown ? open?.confirm : undefined;
        const dialogId = dialogIdFor(confirmClass);
        return (
          <ConfirmDialog
            key={confirmClass}
            id={dialogId}
            open={shown}
            title={current?.title ?? ""}
            confirmLabel={current?.confirmLabel ?? "Proceed"}
            danger={current?.danger ?? false}
            onConfirm={proceed}
            onCancel={cancel}
          >
            <p>{current?.body ?? ""}</p>
            {current !== undefined && current.titles.length > 0 && (
              <ul className="mt-3 max-h-40 overflow-y-auto rounded border border-zinc-200 bg-zinc-50 p-2 text-sm text-zinc-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-200">
                {current.titles.map((title, index) => (
                  <li key={`${index}-${title}`} className="truncate">
                    {title}
                  </li>
                ))}
              </ul>
            )}
            {skippable(confirmClass) && (
              <label className="mt-4 flex min-h-11 cursor-pointer select-none items-center gap-2 text-sm text-zinc-600 dark:text-zinc-300 sm:min-h-9">
                <input
                  type="checkbox"
                  id={`${dialogId}-dont-show`}
                  checked={shown && dontAsk}
                  className="size-5 flex-none rounded border-zinc-300 text-emerald-600 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 dark:border-zinc-600 dark:focus-visible:ring-emerald-400"
                  onChange={(event) => setDontAsk(event.target.checked)}
                />
                {current?.checkboxLabel ?? ""}
              </label>
            )}
          </ConfirmDialog>
        );
      })}
    </>
  );
});

/** One Initiative's presence as the rows read it: everyone else's selections, and who is online. */
function presenceView(state: DomainState, id: number): RowPresence {
  const current = presenceOf(state, id);
  return { selections: selectionsOf(current, state.user?.id ?? null), online: onlineIds(current) };
}

function TreeSection({
  id,
  model,
  actions,
}: {
  id: number;
  model: TreeModel;
  actions: RefObject<HeaderActions | null>;
}) {
  const { api, stores, connection, sync, escalate } = useServices();
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
  // Each row reads the selection through this rather than through the tree
  // context, so selecting costs two rows, not the tree (item 2.2.3).
  const selection = useMemo(() => selectionOf(stores.ui), [stores.ui]);
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

  // Who else is here and what they have selected (item 3.4.2), as a store each
  // row reads for itself (7.17). Fed straight from the store the channel
  // writes, outside React: a presence echo — this window's own selection
  // coming back, most often — reaches only the rows whose badges or dot it
  // changed, and re-renders nothing above them. Seeded synchronously, so the
  // first paint already wears the badges of whoever was here.
  const presence = useMemo(
    () => createPresenceStore(presenceView(stores.domain.get(), id)),
    [stores.domain, id],
  );
  useEffect(() => {
    let filed = presenceOf(stores.domain.get(), id);
    let filedMe = stores.domain.get().user?.id ?? null;
    const file = () => {
      const state = stores.domain.get();
      const current = presenceOf(state, id);
      const me = state.user?.id ?? null;
      if (current === filed && me === filedMe) return;
      filed = current;
      filedMe = me;
      presence.set(presenceView(state, id));
    };
    file();
    return stores.domain.subscribe(file);
  }, [stores.domain, id, presence]);
  // `viewer_plus` is not in the tree read, so the client assumes it is off and
  // a viewer sees no Progress control it cannot use (item 1.2.3).
  const permissions = useMemo(() => permissionsFor(model.header.role), [model.header.role]);

  const inFlight = useMemo(() => createStore<InFlightState>(NOTHING_IN_FLIGHT), []);
  const { history } = useStore(inFlight);
  // The model and the pending marks as each row reads them (7.18): views over
  // the two stores, outside React, so a write reaches the rows it changed and
  // re-renders nothing above them.
  const marks = useMemo(
    () =>
      derive(
        inFlight,
        (state): RowMarks => ({
          savingIds: savingIds(state.pending),
          recomputingIds: recomputingIds(state.pending),
          rowKeys: state.rowKeys,
          rejection: state.rejection,
        }),
      ),
    [inFlight],
  );
  const tasks = useMemo(
    () => createTaskReader(derive(stores.domain, (state: DomainState) => state.trees[id]), marks),
    [stores.domain, id, marks],
  );
  // Stand-in ids for added rows, unique across this tree's life: negative by
  // contract, and never reused so two adds in flight cannot share a key.
  const standIn = useRef(0);

  // A write's own broadcast can settle it before its reply does (1.4.1): the
  // session says so, and the marks clear then — the row stops being pink the
  // moment truth is on screen, whichever way truth arrived.
  useEffect(
    () =>
      sync.onSettled(id, ({ flight, createdId }) => {
        inFlight.set((current) => ({
          ...current,
          pending: settle(current.pending, flight.key),
          rowKeys: alias(current.rowKeys, createdId, flight.tempId),
        }));
      }),
    [id, inFlight, sync],
  );

  // One adapter per mounted tree. It reads the model and the members off the
  // store at submit time, so a batch is always built from what is current —
  // including the predictions already on screen, which is what the user is
  // acting on.
  const adapter = useMemo(() => {
    const contextFor = (initiativeId: number, model: TreeModel) => ({
      model,
      memberIds: membersOf(stores.domain.get(), initiativeId).map((member) => member.user_id),
    });

    // Item 5.2.1: the guess goes on screen and its rows go pending, in the same
    // synchronous step as the batch is queued — before anything is sent.
    const onSubmit = (submission: Submission): void => {
      const { initiativeId, write, key } = submission;
      const current = stores.domain.get().trees[initiativeId];
      if (current === undefined) return;

      // An undo or redo predicts nothing — what it reverses is the server's to
      // say — but it holds its place in line, so its reply lands on the
      // canonical it was sent from and never on a stale one.
      if (write === null) {
        sync.begin(initiativeId, { key, predict: (model) => model, tempId: null });
        return;
      }

      standIn.current -= 1;
      const tempId = write.kind === "add" ? standIn.current : null;
      const predict = (base: TreeModel): TreeModel =>
        predictWrite(write, contextFor(initiativeId, base), tempId ?? -1) ?? base;

      // The session puts the fold on screen; the marks follow in the same step.
      const shown = sync.begin(initiativeId, { key, predict, tempId });
      if (shown === undefined) return;

      const scope = scopeFor(current, shown, [targetOf(write, tempId ?? -1)], submission.affectedIds);
      inFlight.set((state) => ({
        ...state,
        pending: beginPending(state.pending, key, scope),
        // A new edit on the same task supersedes what was refused before.
        rejection:
          write.kind === "edit" && state.rejection?.id === write.id ? null : state.rejection,
      }));
    };

    const onResult = (submission: Submission, result: SubmitResult): void => {
      const { initiativeId, key, write } = submission;

      if (result.ok) {
        // Item 5.2.2: truth lands on canonical; the prediction is dropped and
        // the ones still pending are re-run on top. An added row's server id
        // is aliased to its stand-in key before the tree re-renders. A write
        // its own broadcast already settled has nothing left to do here.
        const { createdId, tempId } = sync.succeed(initiativeId, key, result.delta, result.seq);
        inFlight.set((current) => ({
          ...current,
          pending: settle(current.pending, key),
          rowKeys: alias(current.rowKeys, createdId, tempId),
        }));
        return;
      }

      // Item 5.2.3: the revert is canonical plus what is still pending. A pane
      // edit keeps its text in the field with the reason beside it; anything
      // else is said out loud.
      sync.reject(initiativeId, key);
      // The field beside a refused edit keeps the API's own words (it names
      // the field); a notice gets one plain sentence by code (item 7.14), and
      // the API's words go to the console.
      const refusedEdit: EditRejection | null =
        write?.kind === "edit"
          ? { id: write.id, fields: write.fields, message: rejectionMessage(result.error) }
          : null;
      warnRejection(write === null ? "undo/redo" : write.kind, result.error);
      // A refused undo or redo is not a lost change — "nothing to undo" is
      // the stack's answer, said in the stack's terms.
      const refusedHistory = write === null ? inFlight.get().history : null;
      inFlight.set((current) => ({
        ...current,
        pending: settle(current.pending, key),
        rejection: refusedEdit ?? current.rejection,
      }));
      if (refusedHistory !== null) {
        pushNotice(stores.ui, {
          kind: "info",
          title: refusedHistory === "undo" ? "Undo" : "Redo",
          message: historySentence(refusedHistory, result.error),
        });
      } else if (refusedEdit === null) {
        pushNotice(stores.ui, { kind: "error", title: REJECTED_TITLE, message: rejectionSentence(result.error) });
      }
    };

    return createAdapter({
      api,
      context: (initiativeId) => {
        const current = stores.domain.get().trees[initiativeId];
        return current === undefined ? undefined : contextFor(initiativeId, current);
      },
      // The batch itself is built from truth, never from a guess: canonical as
      // the previous reply (or the last delta) left it.
      sendContext: (initiativeId) => {
        const canonical = sync.canonical(initiativeId);
        return canonical === undefined ? undefined : contextFor(initiativeId, canonical);
      },
      onSubmit,
      onResult,
    });
  }, [api, inFlight, stores.domain, stores.ui, sync]);

  const submit = useCallback(
    (write: TreeWrite) => {
      // Everything that happens on the way out and back is the adapter's hooks.
      void adapter.submit(id, write);
    },
    [adapter, id],
  );

  // Undo / redo: one at a time, its button latched until the reply lands
  // (§6.7). The press is acknowledged in the same frame; the tree changes
  // when the server says what it reversed.
  const onHistory = useCallback(
    (action: "undo" | "redo") => {
      if (inFlight.get().history !== null) return;
      inFlight.set((state) => ({ ...state, history: action }));
      void adapter.submitHistory(id, action).finally(() => {
        inFlight.set((state) => ({ ...state, history: null }));
      });
    },
    [adapter, id, inFlight],
  );
  const historyControls = useMemo(
    () => ({ busy: history, onHistory }),
    [history, onHistory],
  );

  // The confirms (items 5.1.4, 7.6) sit between an intent and the adapter:
  // asked from the model, client-side, before anything is sent (§6.5).
  const storage = useMemo(browserKeyValueStore, []);
  const confirm = useConfirm({ model, submit, storage });
  const { request } = confirm;
  const onIntent = useCallback((intent: TreeIntent) => request(intent), [request]);
  const onAdd = useCallback((added: AddRequest) => request({ kind: "add", request: added }), [request]);

  // A header edit (7.10.1, 7.10.3): predicted on the header at once and sent
  // as one `update initiative`, outside the tree's queue — it touches no row.
  // The prediction goes on canonical, so the next reply's or delta's rebase
  // keeps it; a refusal puts the field back and says so.
  const patchHeader = useCallback(
    (patch: (header: HeaderRecord) => HeaderRecord): void => sync.patchHeader(id, patch),
    [id, sync],
  );
  const commitHeader = useCallback(
    (fields: HeaderFields): void => {
      const current = stores.domain.get().trees[id];
      if (current === undefined) return;
      const edit = headerEdit(current.header, fields);
      if (edit === null) return;
      const prior = current.header;
      patchHeader(() => edit.next);
      void api
        .post<unknown>("/operations", edit.request, { "idempotency-key": crypto.randomUUID() })
        .then((result) => {
          if (result.ok) {
            patchHeader((header) => adoptHeaderReply(header, result.data));
            return;
          }
          patchHeader((header) => revertHeader(header, prior, fields));
          warnRejection("the header edit", result.error);
          pushNotice(stores.ui, {
            kind: "error",
            title: REJECTED_TITLE,
            message: rejectionSentence(result.error),
          });
        });
    },
    [api, id, patchHeader, stores],
  );

  // Read once, off the address bar the screen arrived on.
  const [deepLinkTaskId] = useState(() => taskParam(window.location.search));

  const tree = useTree({
    model,
    tasks,
    initiativeId: id,
    members,
    presence,
    permissions,
    rows,
    selectedId,
    select,
    selection,
    deepLinkTaskId,
    onIntent,
    onAdd,
    onHistory,
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

  const { onOpenAdd } = tree.ctx;
  useEffect(() => {
    actions.current = { addRoot: () => onOpenAdd({ kind: "root" }), commitHeader };
    return () => {
      actions.current = null;
    };
  }, [actions, commitHeader, onOpenAdd]);

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
  const selected = selectedId;

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
        history={historyControls}
        announcement={tree.announcement}
      />
      <ShortcutsOverlay open={tree.shortcutsOpen} onClose={tree.closeShortcuts} />
      <ConfirmDialogs
        open={confirm.open}
        dontAsk={confirm.dontAsk}
        setDontAsk={confirm.setDontAsk}
        proceed={confirm.proceed}
        cancel={confirm.cancel}
      />
      {/* The Details pane (item 3.4.3): opens with the selection, from the
          model alone — nothing here waits on the network (§6). A selected id
          the model no longer holds (deleted under us) opens nothing. */}
      {selected !== null && model.tasks[selected] !== undefined && (
        <Pane onClose={() => select(null)}>
          <TaskDetails ctx={tree.ctx} id={selected} onClose={() => select(null)} />
        </Pane>
      )}
    </div>
  );
}
