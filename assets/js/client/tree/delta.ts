// Canonical records entering the model (m04.02 items 1.5.1–1.5.2).
//
// This is the ONLY way server truth gets into a `TreeModel`. An operation's
// acknowledgement, an undo/redo result and a whole refetched snapshot all become
// the same `TreeDelta` and go through the same `applyDelta`, so there is one
// merge rule to understand and one place a reconciliation bug can live — and
// the Arc 3 live envelope will land on the same path.
//
// Applying the same delta twice leaves the model exactly as it was after the
// first time: a duplicate broadcast, a retried operation and a replayed queue
// entry all have to be harmless.

import type { InitiativeTree, Priority, TaskEditor, TaskStatus } from "../api/types.ts";
import type { InitiativeHeader, TaskRecord, TreeModel } from "./model.ts";
import { ancestors, headerFrom } from "./model.ts";
import { relabel } from "./labels.ts";
import { predictHeader, recomputeBranches } from "./progress.ts";
import { putRecord, resortParents, setChildOrder } from "./ops.ts";
import { InvalidTreeError, validateSnapshot } from "./validate.ts";

/** A partial record: whatever the server said about this task, plus its id. */
export type TaskUpsert = Partial<TaskRecord> & { id: number };

export interface TreeDelta {
  upserts: TaskUpsert[];
  removed: number[];
  initiative?: Partial<InitiativeHeader>;
}

/** The `task_result/1` shape an operation answers with. */
export interface TaskResult {
  id: number;
  type: string;
  title: string;
  parent_id: number;
  status: TaskStatus;
  done: boolean;
  progress: number;
  manual_progress: number;
  priority: Priority;
  assignee_id: number | null;
  /** Who made this write and when (m04.02 2.4); left alone when absent. */
  updated_by?: TaskEditor | null;
  updated_at?: string;
  version: number;
}

/** A history record: the op result plus the two fields a reversal can change. */
export interface HistoryRecord extends TaskResult {
  position: number;
  description: string | null;
}

/** The `history` operation's result (`add history`, m04.02 item 3.1.2). */
export interface HistoryResult {
  action: "undo" | "redo";
  kind: string;
  upserts: HistoryRecord[];
  removed: number[];
  /** The reversal is not expressible as a task delta — read it again instead. */
  refetch: boolean;
}

/** One operation result as a delta. Fields it does not carry are left alone. */
export function deltaFromOpResult(result: TaskResult): TreeDelta {
  return { upserts: [upsertFromResult(result)], removed: [] };
}

/**
 * An undo/redo result as a delta. History records carry `position`, so a
 * reversed reorder or reparent lands in the slot the server put it in rather
 * than merely under the right parent. `refetch` is the caller's to act on — a
 * refetch is a read, and this module does no reading.
 */
export function deltaFromHistoryResult(result: HistoryResult): TreeDelta {
  return {
    upserts: result.upserts.map((record) => ({
      ...upsertFromResult(record),
      position: record.position,
      description: record.description,
    })),
    removed: [...result.removed],
  };
}

function upsertFromResult(result: TaskResult): TaskUpsert {
  return {
    id: result.id,
    title: result.title,
    parent_id: result.parent_id,
    status: result.status,
    done: result.done,
    progress: result.progress,
    manual_progress: result.manual_progress,
    priority: result.priority,
    assignee_id: result.assignee_id,
    version: result.version,
    ...(result.updated_by !== undefined ? { updated_by: result.updated_by } : {}),
    ...(result.updated_at !== undefined ? { updated_at: result.updated_at } : {}),
  };
}

/**
 * A whole re-read as a delta, so a refetch goes through the same door as an
 * acknowledgement. Pass the model being replaced and the delta also removes the
 * tasks that are no longer there; without it, it only upserts.
 *
 * A read that cannot be a tree throws, the same way `fromSnapshot` does: an
 * empty delta would be indistinguishable from an Initiative with no tasks, and
 * the caller is the one that decides whether to refetch or to say so.
 */
export function deltaFromSnapshot(tree: InitiativeTree, previous?: TreeModel): TreeDelta {
  const verdict = validateSnapshot(tree);
  if (!verdict.ok) throw new InvalidTreeError(verdict.reason);

  const upserts: TaskUpsert[] = [];
  const present = new Set<number>();

  const walk = (nodes: InitiativeTree["tasks"]): void => {
    for (const node of nodes) {
      const { children, ...record } = node;
      upserts.push({
        ...record,
        sort_mode: record.sort_mode ?? null,
        sort_reverse: record.sort_reverse ?? false,
      });
      present.add(node.id);
      walk(children);
    }
  };
  walk(tree.tasks);

  const removed =
    previous === undefined
      ? []
      : Object.keys(previous.tasks)
          .map(Number)
          .filter((id) => !present.has(id));

  return { upserts, removed, initiative: headerFrom(tree) };
}

/**
 * Merges canonical records into the model. An upsert patches the fields it
 * carries over the record that is there; a task whose `parent_id` changed moves
 * under its new parent (at its `position` when the delta knows one, appended
 * when it does not); `removed` takes whole subtrees out.
 */
export function applyDelta(model: TreeModel, delta: TreeDelta): {
  model: TreeModel;
  affected: number[];
} {
  let next = model;
  const affected: number[] = [];
  const touchedParents = new Set<number>();
  // Branches whose sort rule the delta changed: a sort result names the
  // branch and its new mode, not its children's new order, so the order is
  // derived here — as `setSort` predicts it — rather than left to the refetch.
  const resorted = new Set<number>();
  // 7.13.1: the branches whose roll-up this delta can move — every changed
  // task's ancestors, and a removed or moved task's former parent with its
  // ancestors — recomputed once the records are in, so a reply lands on the
  // right number without waiting for the refetch. Records the delta itself
  // carries keep the server's number.
  const branches: number[] = [];
  const carried = new Set(delta.upserts.map((upsert) => upsert.id));
  const chainFrom = (parentId: number): number[] =>
    parentId === next.rootId ? [] : [parentId, ...ancestors(next, parentId)];

  for (const id of delta.removed) {
    const record = next.tasks[id];
    if (record === undefined) continue;
    touchedParents.add(record.parent_id);
    branches.push(...chainFrom(record.parent_id));
    const doomed = collectSubtree(next, id);
    const tasks = { ...next.tasks };
    const childIds = { ...next.childIds };
    for (const doomedId of doomed) {
      delete tasks[doomedId];
      delete childIds[doomedId];
      affected.push(doomedId);
    }
    next = { ...next, tasks, childIds };
    next = setChildOrder(
      next,
      record.parent_id,
      (next.childIds[record.parent_id] ?? []).filter((siblingId) => siblingId !== id),
    );
  }

  for (const upsert of delta.upserts) {
    const existing = next.tasks[upsert.id];
    const merged: TaskRecord = existing === undefined ? blank(upsert) : { ...existing, ...upsert };
    const oldParentId = existing?.parent_id;
    const parentId = merged.parent_id;
    if (
      existing !== undefined &&
      (existing.sort_mode !== merged.sort_mode || existing.sort_reverse !== merged.sort_reverse)
    ) {
      resorted.add(merged.id);
    }

    next = putRecord(next, merged);
    if (next.childIds[merged.id] === undefined) {
      next = { ...next, childIds: { ...next.childIds, [merged.id]: [] } };
    }

    const siblings = next.childIds[parentId] ?? [];
    const slot = upsert.position;
    const wanted = slot === undefined ? null : slot;
    const moved = oldParentId !== parentId;
    const misplaced = slot !== undefined && siblings.indexOf(merged.id) !== slot;

    if (moved || misplaced || !siblings.includes(merged.id)) {
      if (oldParentId !== undefined && oldParentId !== parentId) {
        next = setChildOrder(
          next,
          oldParentId,
          (next.childIds[oldParentId] ?? []).filter((siblingId) => siblingId !== merged.id),
        );
        touchedParents.add(oldParentId);
        branches.push(...chainFrom(oldParentId));
      }
      next = place(next, parentId, merged.id, wanted);
      touchedParents.add(parentId);
    }

    branches.push(...ancestors(next, merged.id));
    affected.push(merged.id);
    for (const ancestorId of ancestors(next, merged.id)) affected.push(ancestorId);
  }

  for (const parentId of touchedParents) {
    next = relabel(next, parentId);
    for (const childId of next.childIds[parentId] ?? []) affected.push(childId);
  }

  const rolled = recomputeBranches(next, branches, carried);
  next = rolled.model;
  affected.push(...rolled.affected);

  // 7.19: a row placed by a reply lands where the parent's sort puts it,
  // not at the slot the op asked for. Manual parents are left alone.
  for (const parentId of touchedParents) resorted.add(parentId);
  if (resorted.size > 0) {
    next = resortParents(next, resorted);
    for (const parentId of resorted) {
      for (const childId of next.childIds[parentId] ?? []) affected.push(childId);
    }
  }

  if (delta.initiative !== undefined) {
    const header = { ...next.header, ...delta.initiative };
    const sameHeader = (Object.keys(header) as (keyof InitiativeHeader)[]).every(
      (key) => next.header[key] === header[key],
    );
    if (!sameHeader) next = { ...next, header };
  } else if (next !== model) {
    next = predictHeader(next);
  }

  // `affected` is what actually moved, not what the delta mentioned: a record
  // the merge left identical is not a re-render anybody needs.
  const changed = [...new Set(affected)].filter(
    (id) => next.tasks[id] !== model.tasks[id],
  );

  return { model: next, affected: changed };
}

function place(
  model: TreeModel,
  parentId: number,
  id: number,
  position: number | null,
): TreeModel {
  const siblings = (model.childIds[parentId] ?? []).filter((siblingId) => siblingId !== id);
  const slot =
    position === null ? siblings.length : Math.max(0, Math.min(position, siblings.length));
  return setChildOrder(model, parentId, [
    ...siblings.slice(0, slot),
    id,
    ...siblings.slice(slot),
  ]);
}

function collectSubtree(model: TreeModel, id: number): number[] {
  const out: number[] = [];
  const seen = new Set<number>();
  const walk = (current: number): void => {
    if (seen.has(current)) return;
    seen.add(current);
    out.push(current);
    for (const childId of model.childIds[current] ?? []) walk(childId);
  };
  walk(id);
  return out;
}

// A task the model has never seen: the delta's fields over the defaults a
// freshly created task has, so an upsert for an unknown id is a create.
function blank(upsert: TaskUpsert): TaskRecord {
  return {
    title: "",
    description: null,
    index: "",
    position: 0,
    parent_id: upsert.parent_id ?? 0,
    depth: 0,
    progress: 0,
    manual_progress: 0,
    status: "open",
    done: false,
    leaf: true,
    priority: "normal",
    assignee_id: null,
    co_assignee_ids: [],
    comment_count: 0,
    cross_references: [],
    referenced_by: [],
    sort_mode: null,
    sort_reverse: false,
    updated_by: null,
    updated_at: null,
    version: 0,
    ...upsert,
  };
}
