// Where a new task goes (m04.02 item 2.2.5).
//
// The LiveView has one add form that teleports between `phx-update="ignore"`
// slots (`DoitAddForm`, app.js ~1090): opening it, placing it and walking it
// with ↑/↓ never touch the server. The client renders the form at the slot
// instead of moving a node, but the slots are the same ones, in the same order,
// and they mean the same thing — so the same key press puts the task in the
// same place.
//
// Slot order is document order: the root slot, then for each task, its
// first-child slot, then its descendants' slots, then the slot just after it.
// A slot inside a collapsed branch is skipped — there is no visible row there
// to nest under or follow.

import type { AddAnchor } from "./context.ts";
import { childIdsOf } from "./model.ts";
import type { TreeModel } from "./model.ts";

export type AddSlot = AddAnchor;

/** A stable key for a slot — what React keys on and what the walk compares. */
export function slotKey(slot: AddSlot): string {
  return slot.kind === "root" ? "add-slot-root" : `add-${slot.kind}-${slot.taskId}`;
}

export function sameSlot(a: AddSlot | null, b: AddSlot | null): boolean {
  if (a === null || b === null) return a === b;
  return slotKey(a) === slotKey(b);
}

/** Every place the form can land, in the order ↑/↓ walk them. */
export function addSlots(model: TreeModel, collapsed: (id: number) => boolean): readonly AddSlot[] {
  const slots: AddSlot[] = [{ kind: "root" }];

  const walk = (parentId: number): void => {
    for (const id of childIdsOf(model, parentId)) {
      slots.push({ kind: "child", taskId: id });
      if (!collapsed(id)) walk(id);
      slots.push({ kind: "sibling", taskId: id });
    }
  };

  walk(model.rootId);
  return slots;
}

/** Where the form goes next, or `null` at the ends of the walk (the thud). */
export function moveSlot(
  slots: readonly AddSlot[],
  current: AddSlot,
  dir: -1 | 1,
): AddSlot | null {
  const at = slots.findIndex((slot) => sameSlot(slot, current));
  if (at === -1) return null;
  return slots[at + dir] ?? null;
}

export interface Placement {
  /** The parent the new task lands under. */
  readonly parentId: number;
  /** Its position among that parent's children. */
  readonly position: number;
}

/**
 * The slot, as the placement a create carries. Root and first-child slots land
 * at the top of their list (`sibling_after_position/1`'s "index 0" case); a
 * sibling slot lands directly after the task it follows.
 */
export function placementFor(model: TreeModel, slot: AddSlot): Placement | null {
  if (slot.kind === "root") return { parentId: model.rootId, position: 0 };
  if (slot.kind === "child") {
    return model.tasks[slot.taskId] === undefined
      ? null
      : { parentId: slot.taskId, position: 0 };
  }

  const record = model.tasks[slot.taskId];
  if (record === undefined) return null;
  const siblings = childIdsOf(model, record.parent_id);
  const at = siblings.indexOf(slot.taskId);
  return { parentId: record.parent_id, position: at === -1 ? siblings.length : at + 1 };
}

/** The base placeholder for a slot — `openRoot` / `openChild` / `openSibling`. */
export function placeholderFor(slot: AddSlot): string {
  if (slot.kind === "root") return "New list / root task...";
  return slot.kind === "child" ? "New subtask..." : "New task...";
}

/** `ADD_MOVE_HINT` — the reposition signifier glued to the placeholder. */
export const ADD_MOVE_HINT = "  (↑↓ to move)";

/** The placeholder as it is actually shown: the intent plus the hint. */
export function placeholderText(slot: AddSlot): string {
  return placeholderFor(slot) + ADD_MOVE_HINT;
}

/** What `onAdd` is handed when the title is submitted. */
export interface AddRequest extends Placement {
  readonly title: string;
}

/**
 * The submission, or `null` when there is nothing to submit — a blank title is
 * not a task, and the form stays open with the cursor where it was rather than
 * sending an empty create. (The form stays open across submits on purpose: the
 * button beside it says "Done", not "Cancel".)
 */
export function submissionFor(
  model: TreeModel,
  slot: AddSlot,
  title: string,
): AddRequest | null {
  const trimmed = title.trim();
  if (trimmed === "") return null;
  const placement = placementFor(model, slot);
  return placement === null ? null : { ...placement, title: trimmed };
}
