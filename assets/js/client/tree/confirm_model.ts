// The confirms that sit between an intent and the adapter (m04.02 items
// 5.1.4 and 7.6, UX_GUARDRAILS 6.5/6.6).
//
// Each one is a question the client can already answer from the model, so it
// opens with no round trip: which ancestors a completion flips, how many
// branches a sort cascade rewrites, whether a done toggle is a whole branch,
// which task a delete takes with its subtasks. The copy is the LiveView's,
// word for word, so the instant path and the server's backstop read the same.
//
// "Don't show this again" is one localStorage key per class, the same keys the
// LiveView's `ConfirmSkips` hook reads, so a choice made on either screen holds
// on the other. The client keeps only the key; the server-side sync is the
// LiveView's own. The delete confirm has no such key: the workspace's never
// did, and "can't be undone" is not a question to stop asking.

import type { KeyValueStore } from "../storage/last_user.ts";
import type { TreeWrite } from "./adapter.ts";
import { moveArgsFor } from "./adapter.ts";
import type { TreeModel } from "./model.ts";
import { ancestors, isBranch, subtreeIds } from "./model.ts";
import { wouldMoveFlipAncestors } from "./ops.ts";

export type ConfirmClass = "cascade-complete" | "completion-flip" | "cascade-sort" | "delete";

export const CONFIRM_CLASSES: readonly ConfirmClass[] = [
  "cascade-complete",
  "completion-flip",
  "cascade-sort",
  "delete",
];

/** The classes with a "don't show this again" box. */
export type SkippableClass = Exclude<ConfirmClass, "delete">;

export function skippable(confirmClass: ConfirmClass): confirmClass is SkippableClass {
  return confirmClass !== "delete";
}

export interface Confirm {
  readonly class: ConfirmClass;
  readonly title: string;
  readonly body: string;
  /** The tasks a completion flip would change, for the list under the body. */
  readonly titles: readonly string[];
  /** The "don't show this again" box's label, or `null` when the class has no box. */
  readonly checkboxLabel: string | null;
  /** The yes control's label — a verb (guardrails §4.1). */
  readonly confirmLabel: string;
  /** The yes destroys something: the control is red, and never the default. */
  readonly danger: boolean;
}

/** More descendant branches than this and "Make descendants inherit" asks first. */
export const CASCADE_SORT_THRESHOLD = 10;

const CHECKBOX_LABEL: Record<SkippableClass, string> = {
  "cascade-complete": "Don't show this again for branch completion changes",
  "completion-flip": "Don't show this again for completion changes",
  "cascade-sort": "Don't show this again for large branch reorgs",
};

/**
 * The confirm a write must clear before it is sent, or `null` when it may go
 * straight through. Changes nothing.
 */
export function confirmFor(model: TreeModel, write: TreeWrite): Confirm | null {
  switch (write.kind) {
    case "toggleComplete":
    case "cascadeComplete":
      return cascadeCompleteConfirm(model, write.id, write.done);

    case "reorder":
    case "indent":
    case "outdent":
    case "move": {
      const args = moveArgsFor(model, write);
      if (args === null) return null;
      return completionFlipConfirm(model, wouldMoveFlipAncestors(model, args), "move");
    }

    case "add": {
      // A new task is open; every done ancestor above its slot reopens.
      const { parentId } = write.request;
      if (parentId === model.rootId || model.tasks[parentId] === undefined) return null;
      const chain = [parentId, ...ancestors(model, parentId)];
      const flips = chain.filter((id) => model.tasks[id]?.status === "done");
      return completionFlipConfirm(model, flips, "new task");
    }

    case "cascadeSort":
      return cascadeSortConfirm(model, write.id);

    case "delete":
      return deleteConfirm(model, write.id);

    default:
      return null;
  }
}

// `cascade_complete` / `cascade_incomplete`: a done toggle on a task with
// children takes the whole branch with it. A leaf toggle never asks.
function cascadeCompleteConfirm(model: TreeModel, id: number, done: boolean): Confirm | null {
  const record = model.tasks[id];
  if (record === undefined || !isBranch(model, id)) return null;
  return {
    class: "cascade-complete",
    title: done ? "Complete this branch?" : "Reopen this branch?",
    body: done
      ? `Mark "${record.title}" and all its subtasks complete?`
      : `Reopen "${record.title}" and all its subtasks?`,
    titles: [],
    checkboxLabel: CHECKBOX_LABEL["cascade-complete"],
    confirmLabel: "Proceed",
    danger: false,
  };
}

// `completion_confirm_message/2`: which way the flipped ancestors go decides
// the sentence — 1 reopens, 2 completes, 3 does both.
function completionFlipConfirm(
  model: TreeModel,
  flips: readonly number[],
  verb: "move" | "new task",
): Confirm | null {
  if (flips.length === 0) return null;
  const reopens = flips.some((id) => model.tasks[id]?.status === "done");
  const completes = flips.some((id) => model.tasks[id]?.status !== "done");
  const body =
    reopens && completes
      ? `This ${verb} will mark some tasks complete and others incomplete.`
      : reopens
        ? `This ${verb} will mark previously completed task(s) as incomplete.`
        : `This ${verb} will mark previously incomplete task(s) as complete.`;
  return {
    class: "completion-flip",
    title: "Confirm completion change",
    body,
    titles: flips.map((id) => model.tasks[id]?.title ?? "").filter((title) => title !== ""),
    checkboxLabel: CHECKBOX_LABEL["completion-flip"],
    confirmLabel: "Proceed",
    danger: false,
  };
}

/** `count_descendant_branches/1`: descendants that themselves have children. */
export function descendantBranchCount(model: TreeModel, id: number): number {
  return subtreeIds(model, id).filter((descendantId) => descendantId !== id && isBranch(model, descendantId))
    .length;
}

function cascadeSortConfirm(model: TreeModel, id: number): Confirm | null {
  if (model.tasks[id] === undefined && id !== model.rootId) return null;
  if (descendantBranchCount(model, id) <= CASCADE_SORT_THRESHOLD) return null;
  const affected = subtreeIds(model, id).filter((descendantId) => descendantId !== id).length;
  return {
    class: "cascade-sort",
    title: "Large branch reorg",
    body:
      `This is a large branch reorg affecting ${affected} task(s). Every descendant ` +
      `branch switches to Inherit — their own sort settings are overwritten and they ` +
      `follow this branch from now on; reversible only via Undo (Arc 5).`,
    titles: [],
    checkboxLabel: CHECKBOX_LABEL["cascade-sort"],
    confirmLabel: "Proceed",
    danger: false,
  };
}

// `delete_task_confirm/1`: a delete takes the subtask tree with it. The copy is
// the workspace's, word for word. A task the model no longer holds asks
// nothing; the adapter sends nothing for it either.
function deleteConfirm(model: TreeModel, id: number): Confirm | null {
  const record = model.tasks[id];
  if (record === undefined) return null;
  return {
    class: "delete",
    title: "Delete task",
    body: `Delete "${record.title}" and all its subtasks? This can't be undone.`,
    titles: [],
    checkboxLabel: null,
    confirmLabel: "Delete",
    danger: true,
  };
}

// --- "don't show this again" ------------------------------------------------

const SKIP_NAMESPACE = "doit:confirm-skip";
const SKIP_VERSION = "1";

export function skipKey(confirmClass: SkippableClass): string {
  return `${SKIP_NAMESPACE}:${confirmClass}`;
}

/**
 * The namespace's version stamp, as `ensureStorageVersion` in `app.js` keeps
 * it: a stamp that is not the current version drops every class key and
 * re-stamps. Run once before the first read.
 */
export function ensureSkipVersion(store: KeyValueStore | null): void {
  if (store === null) return;
  try {
    const sentinel = `${SKIP_NAMESPACE}:_v`;
    if (store.getItem(sentinel) === SKIP_VERSION) return;
    for (const confirmClass of CONFIRM_CLASSES) {
      if (skippable(confirmClass)) store.removeItem(skipKey(confirmClass));
    }
    store.setItem(sentinel, SKIP_VERSION);
  } catch {
    // Blocked storage: every confirm asks, which is the safe default.
  }
}

export function suppressed(store: KeyValueStore | null, confirmClass: ConfirmClass): boolean {
  if (store === null || !skippable(confirmClass)) return false;
  try {
    return store.getItem(skipKey(confirmClass)) === "1";
  } catch {
    return false;
  }
}

export function suppress(store: KeyValueStore | null, confirmClass: ConfirmClass): void {
  if (store === null || !skippable(confirmClass)) return;
  try {
    store.setItem(skipKey(confirmClass), "1");
  } catch {
    // The choice costs us the memory of it, not the write it was made on.
  }
}

/** The dialog each class renders as — the ids the LiveView's modals carry. */
export function dialogIdFor(confirmClass: ConfirmClass): string {
  switch (confirmClass) {
    case "cascade-complete":
      return "cascade-confirm";
    case "completion-flip":
      return "move-flip-confirm";
    case "cascade-sort":
      return "cascade-sort-confirm";
    case "delete":
      return "delete-confirm";
  }
}
