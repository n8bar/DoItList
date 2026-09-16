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

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { RowPreferences } from "../state/preferences.ts";
import type { AddRequest, AddSlot } from "./add_form_model.ts";
import { addSlots, moveSlot, sameSlot } from "./add_form_model.ts";
import type { AddAnchor, TreeContext, TreeIntent } from "./context.ts";
import type { KeyOutcome } from "./keyboard_model.ts";
import type { TreeModel } from "./model.ts";
import type { Permissions } from "./permissions.ts";
import type { RowUser } from "./row_model.ts";
import { canProgress } from "./permissions.ts";
import type { CollapseStore } from "./tree_model.ts";
import { readCollapsed, seedCollapsed, visibleRows, writeCollapsed } from "./tree_model.ts";
import { revealPlan } from "./reveal_model.ts";
import { keptSelection, noSelection, rememberSelection } from "./selection_model.ts";
import type { SelectionState } from "./selection_model.ts";
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
  initiativeId: number;
  members: ReadonlyMap<number, RowUser>;
  permissions: Permissions;
  rows: RowPreferences;
  /** A write the user asked for. Read-only until the operation adapter lands. */
  onIntent: (intent: TreeIntent) => void;
  /** A new task the user typed. Same. */
  onAdd: (request: AddRequest) => void;
  /** A key that asked for something this tree cannot do. */
  onBlocked: () => void;
  /** The selected task id, from the `ui` store, and the writer for it. */
  selectedId: number | null;
  select: (id: number | null) => void;
  /** The task a `?task=<id>` link named, revealed once per value. */
  deepLinkTaskId?: number | null;
  /** Where collapse state is kept. Injected so a test can hand it a fake. */
  store?: CollapseStore | null;
}

export interface TreeState {
  ctx: TreeContext;
  addSlot: AddSlot | null;
  addTitle: string;
  onAddTitleChange: (title: string) => void;
  onAddMove: (dir: -1 | 1) => void;
  onAddClose: () => void;
  onAdd: (request: AddRequest) => void;
  shortcutsOpen: boolean;
  closeShortcuts: () => void;
  /** Opens the branches between the root and `id`, then selects it. */
  reveal: (id: number) => void;
}

export function useTree(options: UseTreeOptions): TreeState {
  const { model, initiativeId, members, permissions, rows, onIntent, onAdd, onBlocked } = options;
  // Selection lives in the `ui` store, not in this hook: it is view state with a
  // session's lifetime, and it has to survive this component re-rendering or
  // remounting (guardrails §7.3). The hook only reads and writes it.
  const { selectedId, select: setSelectedId } = options;
  const store = useMemo(
    () => (options.store === undefined ? browserCollapseStore() : options.store),
    [options.store],
  );

  // Seeded SYNCHRONOUSLY, before the first render decides what is visible. Read
  // in an effect instead and a deep link would look at an empty set on mount,
  // conclude there was nothing to expand, and leave its task buried.
  const [collapsedIds, setCollapsedIds] = useState<ReadonlySet<number>>(() =>
    seedCollapsed(model, (id) => readCollapsed(store, initiativeId, id)),
  );
  const [addSlot, setAddSlot] = useState<AddSlot | null>(null);
  // The typed title lives here, not in the form: walking to another slot
  // re-parents the form element and React remounts it, and the whole point of
  // the walk is that what you have typed comes with you.
  const [addTitle, setAddTitle] = useState("");
  const [shortcutsOpen, setShortcutsOpen] = useState(false);

  // A refetch can bring tasks this tree has never seen; they inherit whatever
  // was saved for them. Already-known ids are never re-read, so a branch the
  // user collapsed since is not re-opened by the next read landing.
  useEffect(() => {
    setCollapsedIds((current) =>
      seedCollapsed(model, (id) => readCollapsed(store, initiativeId, id), current),
    );
  }, [model, initiativeId, store]);

  const collapsed = useCallback((id: number) => collapsedIds.has(id), [collapsedIds]);

  const setCollapsed = useCallback(
    (id: number, value: boolean) => {
      // Saved first, so a re-render cannot race the write and read back stale.
      writeCollapsed(store, initiativeId, id, value);
      setCollapsedIds((current) => {
        if (current.has(id) === value) return current;
        const next = new Set(current);
        if (value) next.add(id);
        else next.delete(id);
        return next;
      });
    },
    [initiativeId, store],
  );

  const onToggleCollapse = useCallback(
    (id: number) => setCollapsed(id, !collapsedIds.has(id)),
    [collapsedIds, setCollapsed],
  );

  const reveal = useCallback(
    (id: number) => {
      const plan = revealPlan(model, id, (other) => collapsedIds.has(other));
      for (const branchId of plan.expand) setCollapsed(branchId, false);
      if (plan.select === null) return;
      setSelectedId(plan.select);
      // Deferred a frame, like the LiveView's `deep-link-task` handler, so the
      // rows that were just expanded are laid out before anything measures.
      const target = plan.select;
      requestAnimationFrame(() => scrollRowIntoView(target));
    },
    [collapsedIds, model, setCollapsed, setSelectedId],
  );

  // One reveal per `?task=` value. Keyed on the id rather than on `reveal`,
  // whose identity changes every time a branch opens or closes — key it on the
  // callback and collapsing an ancestor of the selected row snaps it open again.
  const deepLinkTaskId = options.deepLinkTaskId ?? null;
  const revealRef = useRef(reveal);
  revealRef.current = reveal;
  const settled = useRef(false);

  useEffect(() => {
    if (deepLinkTaskId !== null) revealRef.current(deepLinkTaskId);
    // Only now may an off-screen selection be cleared: before this the branch
    // the link points into has not been expanded yet.
    settled.current = true;
  }, [deepLinkTaskId]);

  const visible = useMemo(() => visibleRows(model, collapsed), [model, collapsed]);
  const slots = useMemo(() => addSlots(model, collapsed), [model, collapsed]);

  // A selected task that has been deleted, or hidden by a collapse, is not a
  // selection any more — otherwise the arrows navigate from a row nobody sees.
  useEffect(() => {
    const kept = keptSelection(
      selectedId,
      visible.map((row) => row.id),
      settled.current,
    );
    if (kept !== selectedId) setSelectedId(kept);
  }, [selectedId, setSelectedId, visible]);

  // "Enter with nothing selected reopens the last task" means the task the user
  // was last on, not the last row in the tree.
  const selection = useRef<SelectionState>(noSelection);
  selection.current = rememberSelection(selection.current, selectedId);
  const lastSelectedId = selection.current.lastSelectedId;

  const openAdd = useCallback(
    (anchor: AddAnchor) => {
      if (!permissions.canEdit) return;
      setAddTitle("");
      setAddSlot(anchor);
    },
    [permissions.canEdit],
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
    [onBlocked, onIntent, onToggleCollapse, openAdd, selectedId, setSelectedId],
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

  const ctx: TreeContext = {
    model,
    initiativeId,
    progressCalc: model.progressCalc,
    permissions,
    rows,
    members,
    selectedTaskId: selectedId,
    // Nothing is in flight until the operation adapter lands (Arc 3).
    savingIds: EMPTY_IDS,
    recomputingIds: EMPTY_IDS,
    canProgress: (id: number) => canProgress(permissions, id),
    collapsed,
    onToggleCollapse,
    onSelect: setSelectedId,
    onOpenAdd: openAdd,
    onIntent,
  };

  return {
    ctx,
    addSlot,
    addTitle,
    onAddTitleChange: setAddTitle,
    onAddMove: useCallback(
      (dir: -1 | 1) => {
        setAddSlot((current) => {
          if (current === null) return current;
          // At either end of the walk the form stays put, as the LiveView's
          // `move()` does when it runs out of slots.
          const next = moveSlot(slots, current, dir);
          return next === null ? current : next;
        });
      },
      [slots],
    ),
    onAddClose: useCallback(() => {
      setAddSlot(null);
      setAddTitle("");
    }, []),
    onAdd,
    shortcutsOpen,
    closeShortcuts: useCallback(() => setShortcutsOpen(false), []),
    reveal,
  };
}

const EMPTY_IDS: ReadonlySet<number> = new Set<number>();

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
