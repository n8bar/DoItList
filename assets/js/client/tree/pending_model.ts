// Which rows are pending, and how (m04.02 item 5.2.1).
//
// A write in flight paints exactly the rows it touches, and nothing else:
// the records it WRITES go pink (`is-saving`) and the ancestors whose roll-up
// it moves show an indeterminate bar (`is-recomputing`) until the server's
// number lands. Several writes can be in flight at once, so the state is one
// scope per submission key and the painted sets are the union — a row stays
// pink while ANY write that touches it is unanswered, and clears the moment
// the last one settles, in whatever order the replies come.
//
// This is ephemeral UI state, not domain: it never enters the tree model.

import type { TreeModel } from "./model.ts";
import { ancestors, subtreeIds } from "./model.ts";

export interface PendingScope {
  /** The records the write changes — painted pink. */
  readonly saving: readonly number[];
  /** The ancestors whose roll-up the write moves — indeterminate bars. */
  readonly recomputing: readonly number[];
}

/** One scope per unanswered submission, by its idempotency key. */
export type PendingMap = ReadonlyMap<string, PendingScope>;

export const NO_PENDING: PendingMap = new Map();

const EMPTY_IDS: ReadonlySet<number> = new Set<number>();

/**
 * The scope of one write: `targetIds` are the records the op is about (the
 * toggled task, the moved task, the new task's stand-in), and `affectedIds`
 * is what the pure op said may have changed. Saving is the targets and their
 * subtrees; recomputing is their ancestors in the tree before and after (a
 * move has two chains). Rows the write removed are not on screen and are
 * painted nowhere.
 */
export function scopeFor(
  before: TreeModel,
  after: TreeModel,
  targetIds: readonly number[],
  affectedIds: readonly number[],
): PendingScope {
  const written = new Set<number>();
  const lineage = new Set<number>();
  for (const id of targetIds) {
    for (const model of [before, after]) {
      if (model.tasks[id] === undefined) continue;
      for (const memberId of subtreeIds(model, id)) written.add(memberId);
      for (const ancestorId of ancestors(model, id)) lineage.add(ancestorId);
    }
  }

  const affected = [...new Set([...targetIds, ...affectedIds])].filter(
    (id) => after.tasks[id] !== undefined,
  );
  return {
    saving: affected.filter((id) => written.has(id)),
    recomputing: affected.filter((id) => lineage.has(id) && !written.has(id)),
  };
}

export function begin(pending: PendingMap, key: string, scope: PendingScope): PendingMap {
  const next = new Map(pending);
  next.set(key, scope);
  return next;
}

/** Clears one submission. Unknown keys are a no-op that keeps identity. */
export function settle(pending: PendingMap, key: string): PendingMap {
  if (!pending.has(key)) return pending;
  const next = new Map(pending);
  next.delete(key);
  return next;
}

/** Every row some in-flight write is changing. */
export function savingIds(pending: PendingMap): ReadonlySet<number> {
  return union(pending, "saving");
}

/** Every row some in-flight write is recomputing, that no write is changing. */
export function recomputingIds(pending: PendingMap): ReadonlySet<number> {
  if (pending.size === 0) return EMPTY_IDS;
  const saving = savingIds(pending);
  const ids = new Set<number>();
  for (const scope of pending.values()) {
    for (const id of scope.recomputing) if (!saving.has(id)) ids.add(id);
  }
  return ids;
}

function union(pending: PendingMap, field: keyof PendingScope): ReadonlySet<number> {
  if (pending.size === 0) return EMPTY_IDS;
  const ids = new Set<number>();
  for (const scope of pending.values()) for (const id of scope[field]) ids.add(id);
  return ids;
}
