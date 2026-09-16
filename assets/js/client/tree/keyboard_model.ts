// The tree's keyboard, decided without a DOM (m04.02 item 2.2.4).
//
// A port of the `.TaskKeys` colocated hook (initiative_workspace_live.ex ~3066)
// and the bindings the shortcuts overlay advertises
// (`DoItWeb.CoreComponents.shortcuts_overlay/1`). The hook reads the DOM for
// every one of these answers — which row is next, whether a move is possible,
// which branch to toggle. Here the model already knows, so the same key press
// is answered without a query and, more to the point, without waiting.
//
// Everything below is display-side: a key either moves the selection (instant,
// client-owned, never a round trip — guardrails §6.5) or produces an *intent*
// for the operation adapter to submit. Nothing here writes.

import type { AddAnchor, TreeIntent } from "./context.ts";
import { childIdsOf } from "./model.ts";
import type { TreeModel } from "./model.ts";
import type { VisibleRow } from "./tree_model.ts";

export interface Modifiers {
  readonly alt?: boolean;
  readonly shift?: boolean;
  readonly ctrl?: boolean;
  readonly meta?: boolean;
}

export type KeyOutcome =
  /** Not one of ours. The browser keeps it. */
  | { kind: "none" }
  /** Move the selection. `null` clears it. */
  | { kind: "select"; id: number | null }
  | { kind: "toggleCollapse"; id: number }
  | { kind: "openAdd"; anchor: AddAnchor }
  /** A write, for the adapter. */
  | { kind: "intent"; intent: TreeIntent }
  /** Put the cursor in a Details field (Alt + P / A). */
  | { kind: "focusField"; field: "priority" | "assignee" }
  | { kind: "shortcuts" }
  /** Refused, and the user should hear it: the thud, not silence. */
  | { kind: "blocked" }
  /** The `idclip` easter egg: show every row's ids. */
  | { kind: "idclip" };

export interface KeyboardState {
  readonly model: TreeModel;
  /** The rows on screen, in order — `tree_model.visibleRows`. */
  readonly visible: readonly VisibleRow[];
  readonly selectedId: number | null;
  /** The last thing selected, so Enter can reopen it. */
  readonly lastId: number | null;
}

const NONE: KeyOutcome = { kind: "none" };
const BLOCKED: KeyOutcome = { kind: "blocked" };

const ARROWS = ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"] as const;
type Arrow = (typeof ARROWS)[number];

function isArrow(key: string): key is Arrow {
  return (ARROWS as readonly string[]).includes(key);
}

function indexOf(visible: readonly VisibleRow[], id: number): number {
  return visible.findIndex((row) => row.id === id);
}

/**
 * Where an arrow moves the selection: up and down step through the rows on
 * screen; left goes to the parent; right goes to the first child, but only when
 * the branch is open — a collapsed branch has no first child on screen to go to.
 * `null` means there is nowhere to go.
 */
export function navTarget(
  visible: readonly VisibleRow[],
  selectedId: number,
  key: Arrow,
): number | null {
  const at = indexOf(visible, selectedId);
  if (at === -1) return null;
  const current = visible[at] as VisibleRow;

  if (key === "ArrowUp" || key === "ArrowDown") {
    return visible[at + (key === "ArrowUp" ? -1 : 1)]?.id ?? null;
  }

  if (key === "ArrowLeft") {
    for (let i = at - 1; i >= 0; i -= 1) {
      const row = visible[i] as VisibleRow;
      if (row.depth < current.depth) return row.id;
    }
    return null;
  }

  const next = visible[at + 1];
  return next !== undefined && next.depth === current.depth + 1 ? next.id : null;
}

/**
 * The four reorganisations that cannot happen: moving the first child up, the
 * last child down, dedenting a top-level task, and indenting with no previous
 * sibling to indent under. `blockedMove/2` in the hook, answered from the model
 * instead of from `previousElementSibling`.
 */
export function blockedMove(model: TreeModel, id: number, key: Arrow): boolean {
  const record = model.tasks[id];
  if (record === undefined) return true;

  const siblings = childIdsOf(model, record.parent_id);
  const at = siblings.indexOf(id);

  if (key === "ArrowUp" || key === "ArrowRight") return at <= 0;
  if (key === "ArrowDown") return at === -1 || at === siblings.length - 1;
  return record.parent_id === model.rootId;
}

/** The reorganisation an Alt + arrow asks for. */
export function moveIntent(id: number, key: Arrow): TreeIntent {
  if (key === "ArrowUp") return { kind: "reorder", id, dir: "up" };
  if (key === "ArrowDown") return { kind: "reorder", id, dir: "down" };
  if (key === "ArrowRight") return { kind: "indent", id };
  return { kind: "outdent", id };
}

/** The `idclip` letter buffer, kept honest one key at a time. */
export function nextIdclipBuffer(
  buffer: string,
  key: string,
): { buffer: string; triggered: boolean } {
  if (key.length !== 1 || !/[a-z]/i.test(key)) return { buffer, triggered: false };
  const next = (buffer + key.toLowerCase()).slice(-6);
  return next === "idclip" ? { buffer: "", triggered: true } : { buffer: next, triggered: false };
}

/**
 * One key press, answered. The caller has already decided this press is the
 * tree's — a text field having focus is the hook's business, not the model's.
 */
export function handleKey(state: KeyboardState, key: string, mods: Modifiers = {}): KeyOutcome {
  if (mods.ctrl === true || mods.meta === true) return NONE;

  if (key === "?") return { kind: "shortcuts" };

  if (key === "Escape") {
    return state.selectedId === null ? NONE : { kind: "select", id: null };
  }

  if (key === "Enter") {
    if (state.selectedId !== null) return { kind: "select", id: null };
    const fallback = state.lastId ?? state.visible[0]?.id ?? null;
    return fallback === null ? NONE : { kind: "select", id: fallback };
  }

  // Home / End reach the ends of a long tree without holding an arrow down.
  if (key === "Home" || key === "End") {
    const row = key === "Home" ? state.visible[0] : state.visible[state.visible.length - 1];
    return row === undefined ? NONE : { kind: "select", id: row.id };
  }

  const selected = state.selectedId;
  if (selected === null) return NONE;

  if (key === " ") return { kind: "toggleCollapse", id: selected };

  if (isArrow(key)) {
    if (mods.alt === true) {
      return blockedMove(state.model, selected, key)
        ? BLOCKED
        : { kind: "intent", intent: moveIntent(selected, key) };
    }
    const target = navTarget(state.visible, selected, key);
    return target === null ? NONE : { kind: "select", id: target };
  }

  if (key === "n" || key === "N") {
    return { kind: "openAdd", anchor: { kind: "child", taskId: selected } };
  }
  if (key === "s" || key === "S") {
    return { kind: "openAdd", anchor: { kind: "sibling", taskId: selected } };
  }

  if (key === "Delete") return { kind: "intent", intent: { kind: "delete", id: selected } };

  // P / A: Alt puts the cursor in the field for a precise edit; plain steps the
  // value forward, Shift steps it back.
  const field = key.length === 1 ? FIELD_KEYS[key.toLowerCase()] : undefined;
  if (field !== undefined) {
    if (mods.alt === true) return { kind: "focusField", field };
    return {
      kind: "intent",
      intent: { kind: "step", id: selected, field, back: mods.shift === true },
    };
  }

  return NONE;
}

const FIELD_KEYS: Readonly<Record<string, "priority" | "assignee" | undefined>> = {
  p: "priority",
  a: "assignee",
};

/**
 * What the help overlay lists, word for word as `@shortcuts` in
 * `core_components.ex`. One wording, so the two trees teach the same keys.
 */
export const SHORTCUTS: readonly (readonly [string, string])[] = [
  ["Enter", "Open the selected task's details — or reopen the last task; again to close"],
  ["Space", "Expand / collapse the selected task"],
  ["↑ ↓", "Select the previous / next task"],
  ["← →", "Select the parent / first child"],
  ["Alt + ↑ ↓ ← →", "Reorder, or dedent / indent, the selected task"],
  ["N", "New subtask of the selected task"],
  ["S", "New sibling of the selected task"],
  ["P / A", "Step priority / assignee (Shift to step back)"],
  ["Alt + P / A", "Focus the priority / assignee field"],
  ["Del", "Delete the selected task (with confirmation)"],
  ["?", "Show this help"],
];
