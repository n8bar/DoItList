// Stored intent against truth as it stands now (m04.03 items 4.4, 4.5).
//
// A write is journaled as what the user MEANT, and the batch is built when it
// is sent. Two intents need more than a rebuild when truth has moved under
// them:
//
//   * an edit refused as stale carries the user's fields; only those go again,
//     with the version the server says the record is at now, so a field the
//     user never touched is never written back over someone else's change
//     (spec §6). Bounded: `MAX_EDIT_ATTEMPTS` sends per submission, counted in
//     the journal so a reload cannot reset it; past that the write is handed
//     back to the user as recoverable (4.6.2) rather than looped;
//   * a move or reorder names its parent and the sibling it was dropped beside.
//     Before it is sent — fresh or replayed — the same relative intent is read
//     against the current tree: a parent that is gone, a cycle, or a role that
//     may no longer move anything is refused here, visibly, without a request;
//     an anchor sibling that is gone falls back to the end of the parent (or
//     its start, if the drop was above the first), and says nothing.
//
// Pure. The adapter calls these at send time; nothing here reads or paints.

import type { ApiError } from "../api/client.ts";
import type { Operation } from "./adapter.ts";
import type { TreeIntent } from "./context.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { childIdsOf, subtreeIds } from "./model.ts";
import { clientRefusal } from "./notice_model.ts";
import type { MoveArgs } from "./ops.ts";
import type { Permissions } from "./permissions.ts";

export type EditWrite = Extract<TreeIntent, { kind: "edit" }>;
export type MoveWrite = Extract<TreeIntent, { kind: "reorder" | "indent" | "outdent" | "move" }>;
type EditField = keyof EditWrite["fields"];

/** Sends per submission: the first, then two rebases. */
export const MAX_EDIT_ATTEMPTS = 3;

/** The refusal for an intent whose target is gone: said by the client, in the server's terms. */
export const TARGET_GONE: ApiError = clientRefusal(
  "conflict",
  "The task this change was for is no longer there; nothing was applied.",
);

/** An edit that hit the bound: someone else is writing the same record faster than this client. */
export const EDIT_CONTENDED: ApiError = clientRefusal("conflict", "Someone else kept changing this.");

export const MOVE_CYCLE: ApiError = clientRefusal("unprocessable_entity", "A task can't be moved inside itself.");

export const NO_PERMISSION: ApiError = clientRefusal("forbidden", "You no longer have permission to do this.");

/**
 * The record as the server holds it now: its version, and whichever of the
 * editable fields the reply (or canonical) carries.
 */
export type CurrentRecord = { readonly version: number } & Partial<Pick<TaskRecord, EditField>>;

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * The `current` record a version conflict carries (`Operations.wire_error/1`):
 * the offending op's, when the reply names one with a numeric version.
 */
export function currentFromConflict(error: ApiError): CurrentRecord | null {
  const payload = error.payload;
  if (!isRecord(payload) || !Array.isArray(payload["results"])) return null;
  for (const result of payload["results"]) {
    if (!isRecord(result) || !isRecord(result["error"])) continue;
    const current = result["error"]["current"];
    if (isRecord(current) && typeof current["version"] === "number") return current as CurrentRecord;
  }
  return null;
}

/**
 * The user's edit, onto the record as it is now: only the fields the user
 * changed, less any that already read as the user wants, with the current
 * version. `null` when nothing is left to send — the edit is already so.
 */
export function rebaseEdit(write: EditWrite, current: CurrentRecord): Operation | null {
  const data: Record<string, unknown> = {};
  for (const field of Object.keys(write.fields) as EditField[]) {
    const value = write.fields[field];
    if (value === undefined) continue;
    if (field in current && current[field] === value) continue;
    data[field] = value;
  }
  if (Object.keys(data).length === 0) return null;
  return { op: "update", type: "task", id: write.id, data: { ...data, expected_version: current.version } };
}

/** What a move comes to against the tree now. */
export type MoveVerdict =
  | { kind: "move"; args: MoveArgs }
  /** Nowhere to go (a reorder at the edge, an indent with no sibling above): nothing to send. */
  | { kind: "nothing" }
  /** Impossible now: said out loud, and no request goes. */
  | { kind: "refused"; error: ApiError };

/**
 * The same relative intent, read against the current structure. Refuses what
 * can no longer be: a role that may not move, a row or parent that is gone, a
 * parent inside the moved subtree. A lost anchor is not a refusal — the slot
 * degrades to the parent's end (`moveArgsFor`).
 */
export function reevaluateMove(write: MoveWrite, model: TreeModel, permissions: Permissions): MoveVerdict {
  if (!permissions.canEdit) return { kind: "refused", error: NO_PERMISSION };
  if (model.tasks[write.id] === undefined) return { kind: "refused", error: TARGET_GONE };
  if (write.kind === "move") {
    const parentHeld = write.parentId === model.rootId || model.tasks[write.parentId] !== undefined;
    if (!parentHeld) return { kind: "refused", error: TARGET_GONE };
    if (write.parentId === write.id || subtreeIds(model, write.id).includes(write.parentId)) {
      return { kind: "refused", error: MOVE_CYCLE };
    }
  }
  const args = moveArgsFor(model, write);
  return args === null ? { kind: "nothing" } : { kind: "move", args };
}

/**
 * The slot a keyboard or drag move lands in, as `moveTask` reads it — shared
 * with the confirm (`confirm_model.ts`) so the flip it predicts is the move that
 * is sent. `null` when there is nowhere to go. A drop that named the sibling it
 * landed beside is placed by that sibling as the list stands now (4.5), not by
 * the index it had when dropped.
 */
export function moveArgsFor(model: TreeModel, write: MoveWrite): MoveArgs | null {
  const record = model.tasks[write.id];
  if (record === undefined) return null;

  switch (write.kind) {
    case "reorder": {
      const siblings = childIdsOf(model, record.parent_id);
      const at = siblings.indexOf(write.id);
      const position = write.dir === "up" ? at - 1 : at + 1;
      if (at === -1 || position < 0 || position >= siblings.length) return null;
      return { id: write.id, parentId: record.parent_id, position, reorder: true };
    }

    case "indent": {
      // Alt+→: first child of the previous sibling (`kbd_indent/3`). A plain
      // reparent with no slot lands at the top of the new parent.
      const siblings = childIdsOf(model, record.parent_id);
      const previous = siblings[siblings.indexOf(write.id) - 1];
      if (previous === undefined) return null;
      return { id: write.id, parentId: previous, position: null };
    }

    case "outdent": {
      // Alt+←: a sibling of the parent, right after it (`kbd_dedent/1`).
      const parent = model.tasks[record.parent_id];
      if (parent === undefined) return null;
      const grandSiblings = childIdsOf(model, parent.parent_id);
      return { id: write.id, parentId: parent.parent_id, position: grandSiblings.indexOf(parent.id) + 1 };
    }

    case "move": {
      const { anchor } = write;
      if (anchor === undefined) {
        return { id: write.id, parentId: write.parentId, position: write.position, reorder: write.reorder };
      }
      // The slot is an index into the destination list without the source.
      const siblings = childIdsOf(model, write.parentId).filter((id) => id !== write.id);
      const at = siblings.indexOf(anchor.id);
      const position =
        at === -1 ? (write.position === 0 ? 0 : null) : anchor.side === "before" ? at : at + 1;
      return { id: write.id, parentId: write.parentId, position, reorder: write.reorder };
    }
  }
}
