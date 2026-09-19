// The tree's live state (m04.02 items 2.2.2, 2.2.3, 2.2.4, 2.2.5).
//
// Everything the tree knows that the server does not: which branches are open,
// which row is selected, where the one add form is parked, and whether the
// shortcuts overlay is up. All of it is client-owned by the rule in AGENTS.md —
// state lives where its lifetime is — and none of it costs a round trip
// (UX_GUARDRAILS §6.5).
//
// The decisions are all in the pure modules (`tree_model.ts`, `keyboard_model.ts`,
// `add_form_model.ts`); this hook is the wiring: React state, `localStorage`,
// the window listener, and turning a `KeyOutcome` into a call.

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";

import type { RowPreferences } from "../state/preferences.ts";
import type { AddRequest, AddSlot } from "./add_form_model.ts";
import { addSlots, moveSlot, sameSlot } from "./add_form_model.ts";
import type { EditField } from "../live/presence_model.ts";
import type { AddAnchor, RemoteChangeSource, TreeContext, TreeIntent } from "./context.ts";
import type { KeyOutcome } from "./keyboard_model.ts";
import type { TreeModel } from "./model.ts";
import type { Permissions } from "./permissions.ts";
import type { RowUser } from "./row_model.ts";
import type { PresenceReader } from "./presence_store.ts";
import { nobodyPresent } from "./presence_store.ts";
import { canProgress } from "./permissions.ts";
import type { CollapseStore } from "./tree_model.ts";
import { collapsedOf, createCollapseStore, setCollapsedIn } from "./collapse_model.ts";
import { readCollapsed, seedCollapsed, visibleRows, writeCollapsed } from "./tree_model.ts";
import { initialSelection, revealPlan } from "./reveal_model.ts";
import { announcementFor } from "./announce_model.ts";
import type { AnnouncedState } from "./announce_model.ts";
import { forgetMissing, noSelection, pendingBranches, prunedSelection, rememberSelection, stillClosed } from "./selection_model.ts";
import type { Selected, SelectionState } from "./selection_model.ts";
import type { Source, TaskReader } from "./task_store.ts";
import { createStore } from "../state/store.ts";
import { useTreeKeyboard } from "./use_tree_keyboard.ts";

/** The tab's `localStorage`, or nothing at all where it is blocked. */
export function browserCollapseStore(): CollapseStore | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

export interface UseTreeOptions {
  model: TreeModel;
  /** The same model as each row reads it (7.18), with the pending marks. */
  tasks: TaskReader;
  initiativeId: number;
  members: ReadonlyMap<number, RowUser>;
  /** Who else is here and what they have selected, as a store each row reads. Nobody, by default. */
  presence?: PresenceReader;
  permissions: Permissions;
  rows: RowPreferences;
  /** A write the user asked for. Read-only until the operation adapter lands. */
  onIntent: (intent: TreeIntent) => void;
  /** A new task the user typed. Same. */
  onAdd: (request: AddRequest) => void;
  /** Ctrl/Cmd+Z and friends: undo or redo on the Initiative's stack. */
  onHistory?: (action: "undo" | "redo") => void;
  /** A key that asked for something this tree cannot do. */
  onBlocked: () => void;
  /** A touch swiped a drag handle instead of holding it. */
  onDragHint?: () => void;
  /** The pane's field-editing presence (m04.03 4.1.1). */
  onEditField?: (field: EditField | null) => void;
  /** Someone else's writes, for the pane's focused field (4.2). */
  remoteChanges?: RemoteChangeSource;
  /** The selected task id, from the `ui` store, and the writer for it. */
  selectedId: number | null;
  select: (id: number | null) => void;
  /** The same selection as each row subscribes to it, so a change costs two rows. */
  selection: Selected;
  /** The task a `?task=<id>` link named, revealed once per value. */
  deepLinkTaskId?: number | null;
  /** Where collapse state is kept. Injected so a test can hand it a fake. */
  store?: CollapseStore | null;
}

export interface TreeState {
  ctx: TreeContext;
  /** The one open add form's slot, as each branch subscribes to it (7.18). */
  addSlot: Source<AddSlot | null>;
  /** The typed title, as the form subscribes to it (7.18). */
  addTitle: Source<string>;
  onAddTitleChange: (title: string) => void;
  onAddMove: (dir: -1 | 1) => void;
  onAddClose: () => void;
  onAdd: (request: AddRequest) => void;
  shortcutsOpen: boolean;
  closeShortcuts: () => void;
  /** The line the tree's live region reads out for the latest change (7.12.2). */
  announcement: string;
  /**
   * The selection this screen resolved on arrival, before anything rendered —
   * the link's task, a kept selection, or nothing. The address bar is written
   * against this, not against the value that was in the store on the way in.
   */
  initialSelectedId: number | null;
  /** Opens the branches between the root and `id`, then selects it. */
  reveal: (id: number) => void;
}

export function useTree(options: UseTreeOptions): TreeState {
  const {
    model,
    tasks,
    initiativeId,
    members,
    permissions,
    rows,
    onIntent,
    onAdd,
    onHistory,
    onBlocked,
    onDragHint,
    onEditField,
    remoteChanges,
  } = options;
  // Selection lives in the `ui` store, not in this hook: it is view state with a
  // session's lifetime, and it has to survive this component re-rendering or
  // remounting (guardrails §7.3). The hook only reads and writes it.
  const { selectedId, select: setSelectedId, selection: selectedReader } = options;
  const store = useMemo(
    () => (options.store === undefined ? browserCollapseStore() : options.store),
    [options.store],
  );

  // The closed set is a store of its own (item 7.9.1): each chevron and
  // children list subscribes for its branch, and this hook reads the whole set
  // below for the keyboard walks and pruning — one source of truth. Seeded
  // SYNCHRONOUSLY, before the first render decides what is visible. Read in an
  // effect instead and a deep link would look at an empty set on mount,
  // conclude there was nothing to expand, and leave its task buried.
  const collapseStore = useMemo(
    () => createCollapseStore(seedCollapsed(model, (id) => readCollapsed(store, initiativeId, id))),
    // Seeded once per Initiative; the effect below folds in later reads.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [initiativeId, store],
  );
  const collapsedIds = useSyncExternalStore(collapseStore.subscribe, collapseStore.get, collapseStore.get);
  const collapseReader = useMemo(() => collapsedOf(collapseStore), [collapseStore]);
  // The open form's slot is a store too (7.18): N re-renders the row that
  // hosts the form, not every branch handed a new prop.
  const addSlot = useMemo(() => createStore<AddSlot | null>(null), []);
  // The typed title lives here, not in the form: walking to another slot
  // re-parents the form element and React remounts it, and the whole point of
  // the walk is that what you have typed comes with you. A store, not state
  // (7.18): the form subscribes, and a keystroke re-renders it alone.
  const addTitle = useMemo(() => createStore(""), []);
  // The model as of this render, for callbacks that must keep their identity
  // across writes (7.18.2) yet act on what is current when they run.
  const modelRef = useRef(model);
  modelRef.current = model;
  const [shortcutsOpen, setShortcutsOpen] = useState(false);

  // A refetch can bring tasks this tree has never seen; they inherit whatever
  // was saved for them. Already-known ids are never re-read, so a branch the
  // user collapsed since is not re-opened by the next read landing.
  useEffect(() => {
    collapseStore.set((current) =>
      seedCollapsed(model, (id) => readCollapsed(store, initiativeId, id), current),
    );
  }, [model, initiativeId, store, collapseStore]);

  const collapsed = useCallback((id: number) => collapsedIds.has(id), [collapsedIds]);

  const setCollapsed = useCallback(
    (id: number, value: boolean) => {
      // Saved first, so a re-render cannot race the write and read back stale.
      writeCollapsed(store, initiativeId, id, value);
      setCollapsedIn(collapseStore, id, value);
    },
    [initiativeId, store, collapseStore],
  );

  // Reads the store, not a captured set: stable across toggles, so the context
  // built on it is too (7.9.1).
  const onToggleCollapse = useCallback(
    (id: number) => setCollapsed(id, !collapseStore.get().has(id)),
    [collapseStore, setCollapsed],
  );

  const deepLinkTaskId = options.deepLinkTaskId ?? null;

  // Decided on the first render, before any effect can act on the selection:
  // selection is per Initiative, and `ui.selectedTaskId` is one field that
  // outlives the screen. Arriving from another Initiative with a task selected
  // there, the stale id used to reach the pruning effect first and clear the row
  // the link had just revealed.
  const resolved = useRef<number | null>(null);
  const first = useRef(true);
  if (first.current) {
    first.current = false;
    resolved.current = initialSelection(model, deepLinkTaskId, selectedId);
  }
  // Branches a reveal has asked to open and is still waiting on.
  const expanding = useRef<readonly number[]>(EMPTY_EXPANDING);

  const reveal = useCallback(
    (id: number) => {
      const plan = revealPlan(modelRef.current, id, (other) => collapseStore.get().has(other));
      // Pruning must not act until these have actually opened: until then the
      // task the link named is still buried, and a prune would clear it.
      // Merged, not replaced: the plan reads the store, which a reveal a
      // moment ago already opened, while the prune still reads the render
      // that has not caught up — forgetting that reveal's branches here let
      // the prune clear the row it had just revealed.
      expanding.current = pendingBranches(expanding.current, plan.expand);
      for (const branchId of plan.expand) setCollapsed(branchId, false);
      if (plan.select === null) return;
      // Written synchronously: the prune below, already scheduled for this
      // commit, reads the store live and so sees this, not the old render.
      setSelectedId(plan.select);
      // Deferred a frame, like the LiveView's `deep-link-task` handler, so the
      // rows that were just expanded are laid out before anything measures.
      const target = plan.select;
      requestAnimationFrame(() => scrollRowIntoView(target));
    },
    [collapseStore, setCollapsed, setSelectedId],
  );

  // One reveal per `?task=` value. Keyed on the id rather than on `reveal` —
  // key it on the callback and a new identity of it would run the link again,
  // snapping a collapsed ancestor of the selected row back open.
  const revealRef = useRef(reveal);
  revealRef.current = reveal;
  const settled = useRef(false);


  useEffect(() => {
    // Applied before anything else runs: what was selected elsewhere is not a
    // selection here.
    setSelectedId(resolved.current);
    if (deepLinkTaskId !== null) revealRef.current(deepLinkTaskId);
    // Only now may an off-screen selection be cleared: before this the branch
    // the link points into has not been expanded yet.
    settled.current = true;
    // Once per arrival. `setSelectedId` is a stable store writer.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [deepLinkTaskId]);

  const visible = useMemo(() => visibleRows(model, collapsed), [model, collapsed]);

  // A selected task that has been deleted, or hidden by a collapse, is not a
  // selection any more — otherwise the arrows navigate from a row nobody sees.
  useEffect(() => {
    // The store, read live, not the captured `selectedId`: on the arrival
    // commit the reveal effect has already moved the selection, and every
    // click and key since writes the store synchronously. Pruning a value
    // from an earlier render (or one remembered from a reveal) cleared a row
    // still on screen and kept one that had just been hidden (item 7.11).
    expanding.current = stillClosed(expanding.current, (id) => collapsedIds.has(id));
    if (expanding.current.length > 0) return;

    const current = selectedReader.get();
    const kept = prunedSelection(selectedReader, visible.map((row) => row.id), settled.current);
    if (kept !== current) setSelectedId(kept);
  }, [collapsedIds, selectedId, selectedReader, setSelectedId, visible]);

  // What a screen reader hears (7.12.2): one line per selection or collapse
  // change, decided against the model once the change has rendered. Nothing
  // is said for the first render — arriving is not a change.
  const [announcement, setAnnouncement] = useState("");
  const announced = useRef<AnnouncedState | null>(null);
  useEffect(() => {
    const before = announced.current;
    const after = { selectedId, collapsedIds };
    announced.current = after;
    if (before === null) return;
    const text = announcementFor(model, before, after);
    if (text !== null) setAnnouncement(text);
  }, [selectedId, collapsedIds, model]);

  // "Enter with nothing selected reopens the last task" means the task the user
  // was last on, not the last row in the tree.
  const selection = useRef<SelectionState>(noSelection);
  selection.current = forgetMissing(
    rememberSelection(selection.current, selectedId),
    (id) => model.tasks[id] !== undefined,
  );
  const lastSelectedId = selection.current.lastSelectedId;

  const openAdd = useCallback(
    (anchor: AddAnchor) => {
      if (!permissions.canEdit) return;
      addTitle.set("");
      addSlot.set(anchor);
    },
    [addSlot, addTitle, permissions.canEdit],
  );

  const onOutcome = useCallback(
    (outcome: KeyOutcome) => {
      switch (outcome.kind) {
        case "select":
          setSelectedId(outcome.id);
          // Keyboard selection has to bring the row with it. Escape clears the
          // selection instead of moving it, and there is nothing to scroll to.
          if (outcome.id !== null) scrollRowIntoView(outcome.id);
          return;
        case "toggleCollapse":
          onToggleCollapse(outcome.id);
          return;
        case "openAdd":
          openAdd(outcome.anchor);
          return;
        case "intent":
          onIntent(outcome.intent);
          return;
        case "history":
          onHistory?.(outcome.action);
          return;
        case "focusField":
          focusPill(selectedId, outcome.field);
          return;
        case "shortcuts":
          setShortcutsOpen(true);
          return;
        case "blocked":
          onBlocked();
          return;
        case "idclip":
          // Doom's noclip, for seeing through a row to its ids. The same class
          // the LiveView toggles, so the same CSS rule reveals the same pill.
          document.documentElement.classList.toggle("debug-task-ids");
          return;
        default:
          return;
      }
    },
    [onBlocked, onHistory, onIntent, onToggleCollapse, openAdd, selectedId, setSelectedId],
  );

  useTreeKeyboard({
    state: {
      model,
      visible,
      selectedId,
      lastId: lastSelectedId,
    },
    onOutcome,
    // The overlay owns Escape and the arrows while it is up.
    enabled: !shortcutsOpen,
  });

  const canProgressId = useCallback((id: number) => canProgress(permissions, id), [permissions]);
  const presence = options.presence ?? nobodyPresent;

  // One identity per set of inputs: `tree.tsx` memoizes each branch on it, so
  // a re-render of the screen that changes none of these — a confirm opening,
  // the pane's own state — costs no row at all. Every input is stable between
  // renders (store values, memoized derivations, stable callbacks); a literal
  // here would defeat that on every render.
  const ctx: TreeContext = useMemo(
    () => ({
      tasks,
      initiativeId,
      permissions,
      rows,
      members,
      presence,
      selection: selectedReader,
      canProgress: canProgressId,
      collapse: collapseReader,
      onToggleCollapse,
      onSelect: setSelectedId,
      onReveal: reveal,
      onOpenAdd: openAdd,
      onIntent,
      ...(onDragHint === undefined ? {} : { onDragHint }),
      ...(onEditField === undefined ? {} : { onEditField }),
      ...(remoteChanges === undefined ? {} : { remoteChanges }),
    }),
    [
      tasks,
      initiativeId,
      permissions,
      rows,
      members,
      presence,
      selectedReader,
      canProgressId,
      collapseReader,
      onToggleCollapse,
      setSelectedId,
      reveal,
      openAdd,
      onIntent,
      onDragHint,
      onEditField,
      remoteChanges,
    ],
  );

  return {
    ctx,
    addSlot,
    addTitle,
    onAddTitleChange: useCallback((title: string) => addTitle.set(title), [addTitle]),
    onAddMove: useCallback(
      (dir: -1 | 1) => {
        addSlot.set((current) => {
          if (current === null) return current;
          // Walked from the store when asked, not memoized on the closed set:
          // a callback that changed on every toggle changed the `form` prop of
          // every branch, and every row rendered for one chevron (7.9.1).
          const slots = addSlots(modelRef.current, (id) => collapseStore.get().has(id));
          // At either end of the walk the form stays put, as the LiveView's
          // `move()` does when it runs out of slots.
          const next = moveSlot(slots, current, dir);
          return next === null ? current : next;
        });
      },
      [addSlot, collapseStore],
    ),
    onAddClose: useCallback(() => {
      addSlot.set(null);
      addTitle.set("");
    }, [addSlot, addTitle]),
    onAdd,
    shortcutsOpen,
    announcement,
    initialSelectedId: resolved.current,
    closeShortcuts: useCallback(() => setShortcutsOpen(false), []),
    reveal,
  };
}

const EMPTY_EXPANDING: readonly number[] = [];

/** Brings a row the keyboard just selected into view, gently. */
function scrollRowIntoView(id: number): void {
  const row = document.getElementById(`task-${id}`);
  row?.scrollIntoView({ block: "nearest", behavior: "auto" });
}

/** Alt+P / Alt+A put focus on the row's own control rather than acting for it. */
function focusPill(id: number | null, field: "priority" | "assignee"): void {
  if (id === null) return;
  const pill = document.querySelector(`#task-${id} [data-pill="${field}"]`);
  if (pill instanceof HTMLElement) pill.focus();
}

/** Re-exported so the screen can ask whether a slot is the open one. */
export { sameSlot };
