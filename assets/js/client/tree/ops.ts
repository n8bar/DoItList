// Pure tree operations (m04.02 items 1.3, 1.4).
//
// Every operation is `(model, args) => {model, affected}`: a new model, and the
// ids whose display may have changed — the task itself, the sibling runs it
// moved through, and both ancestor chains. Nothing is mutated and untouched
// records keep their object identity, so a change costs render work in
// proportion to itself (spec §9).
//
// These are ports of `DoIt.Tasks`, not a second implementation of it: the
// server still validates, orders and decides. What happens here is the local
// half of an optimistic write — applied at once so the user is acknowledged in
// the same frame (UX_GUARDRAILS §6), then replaced by the canonical records
// through `delta.ts`.

import type { Priority, SortMode } from "../api/types.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { ancestors, subtreeIds } from "./model.ts";
import { relabel } from "./labels.ts";
import { predictFrom, predictHeader, predictLineage, predictSubtreeAndLineage } from "./progress.ts";
import { comparable, resolveSort, sortIds } from "./sort.ts";

export interface OpResult {
  model: TreeModel;
  affected: number[];
}

/**
 * An operation the tree cannot make. The server answers the same two ways:
 * `"missing"` is `:not_found` — an id the model does not hold, which is a bug
 * or a stale view — and `"cycle"` is the refused move, which is the user
 * asking for something impossible.
 */
export interface OpError {
  error: "cycle" | "missing";
}

export type MoveResult = OpResult | OpError;

export function failed(result: MoveResult): result is OpError {
  return "error" in result;
}

// --- structural primitives (shared with delta.ts) ---------------------------

/** Writes one record in place, leaving every other record's identity alone. */
export function putRecord(model: TreeModel, record: TaskRecord): TreeModel {
  const current = model.tasks[record.id];
  if (current !== undefined && sameRecord(current, record)) return model;
  return { ...model, tasks: { ...model.tasks, [record.id]: record } };
}

/**
 * Field-for-field equality, with the three array fields compared element-wise.
 * A freshly parsed read builds new arrays for `co_assignee_ids`,
 * `cross_references` and `referenced_by` even when nothing about them changed;
 * comparing those by reference would make every record on every refetch a new
 * object, and re-render the whole tree for no reason (spec §1).
 */
function sameRecord(a: TaskRecord, b: TaskRecord): boolean {
  return (Object.keys(b) as (keyof TaskRecord)[]).every((key) => {
    const left = a[key];
    const right = b[key];
    if (Array.isArray(left) && Array.isArray(right)) return sameList(left, right);
    return left === right;
  });
}

/** Element-wise, one level into the row objects the references are made of. */
function sameList(a: readonly unknown[], b: readonly unknown[]): boolean {
  if (a.length !== b.length) return false;
  return a.every((left, index) => {
    const right = b[index];
    if (left === right) return true;
    if (!isRow(left) || !isRow(right)) return false;
    const keys = Object.keys(left);
    if (keys.length !== Object.keys(right).length) return false;
    return keys.every((key) => left[key] === right[key]);
  });
}

function isRow(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/**
 * Sets `parentId`'s child order and stamps each child's `position` to its slot,
 * so the record and the order can never disagree. Also keeps the parent's
 * `leaf` honest, since its child set just changed.
 */
export function setChildOrder(
  model: TreeModel,
  parentId: number,
  ids: readonly number[],
): TreeModel {
  const tasks: Record<number, TaskRecord> = { ...model.tasks };
  let changed = false;

  ids.forEach((id, index) => {
    const record = tasks[id];
    if (record === undefined) return;
    if (record.position !== index || record.parent_id !== parentId) {
      tasks[id] = { ...record, position: index, parent_id: parentId };
      changed = true;
    }
  });

  const parent = tasks[parentId];
  if (parent !== undefined && parent.leaf !== (ids.length === 0)) {
    tasks[parentId] = { ...parent, leaf: ids.length === 0 };
    changed = true;
  }

  const sameOrder =
    (model.childIds[parentId] ?? []).length === ids.length &&
    ids.every((id, index) => model.childIds[parentId]?.[index] === id);

  if (sameOrder && !changed) return model;

  return {
    ...model,
    tasks: changed ? tasks : model.tasks,
    childIds: sameOrder ? model.childIds : { ...model.childIds, [parentId]: [...ids] },
  };
}

/** Takes `id` out of its parent's order without touching the record itself. */
function detach(model: TreeModel, id: number): TreeModel {
  const record = model.tasks[id];
  if (record === undefined) return model;
  const siblings = model.childIds[record.parent_id] ?? [];
  if (!siblings.includes(id)) return model;
  return setChildOrder(
    model,
    record.parent_id,
    siblings.filter((siblingId) => siblingId !== id),
  );
}

/** Puts `id` under `parentId` at `position` (or at the end when it is null). */
function attach(
  model: TreeModel,
  parentId: number,
  id: number,
  position: number | null,
): TreeModel {
  const siblings = (model.childIds[parentId] ?? []).filter((siblingId) => siblingId !== id);
  const slot = position === null ? siblings.length : Math.max(0, Math.min(position, siblings.length));
  const next = [...siblings.slice(0, slot), id, ...siblings.slice(slot)];
  return setChildOrder(model, parentId, next);
}

/**
 * Re-orders each parent's children by its resolved sort mode, at most once per
 * parent — `maybe_resort_children/1`'s dedup, without the batch scope.
 */
function resortParents(model: TreeModel, parentIds: Iterable<number>): TreeModel {
  let current = model;
  for (const parentId of new Set(parentIds)) {
    const [mode, reverse] = resolveSort(current, parentId);
    if (!comparable(mode)) continue;
    const ids = current.childIds[parentId] ?? [];
    const sorted = sortIds(current, ids, mode, reverse);
    const moved = sorted.some((id, index) => ids[index] !== id);
    if (!moved) continue;
    current = relabel(setChildOrder(current, parentId, sorted), parentId);
  }
  return current;
}

const DONE_STATUS = "done";

// --- add --------------------------------------------------------------------

export interface AddTaskArgs {
  /** The client's stand-in id until the server answers. Negative by contract. */
  tempId: number;
  parentId: number;
  /** 0-based slot among the new siblings; the end when absent. */
  position?: number | null;
  title: string;
  priority?: Priority;
  assigneeId?: number | null;
}

/**
 * Adds a task, placed per ProductSpec §10.8: at the form's slot under a manual
 * parent, appended when no slot is given, and wherever the parent's own sort
 * puts it when that parent is auto-sorted.
 */
export function addTask(model: TreeModel, args: AddTaskArgs): MoveResult {
  const { tempId, parentId } = args;
  // A parent the model does not hold would leave a child list behind for a task
  // that is not there — a tree the validator rejects. Say so instead.
  if (parentId !== model.rootId && model.tasks[parentId] === undefined) {
    return { error: "missing" };
  }

  const record: TaskRecord = {
    id: tempId,
    title: args.title,
    description: null,
    index: "",
    position: 0,
    parent_id: parentId,
    depth: 0,
    progress: 0,
    manual_progress: 0,
    status: "open",
    done: false,
    leaf: true,
    priority: args.priority ?? "normal",
    assignee_id: args.assigneeId ?? null,
    co_assignee_ids: [],
    comment_count: 0,
    cross_references: [],
    referenced_by: [],
    sort_mode: null,
    sort_reverse: false,
    version: 0,
  };

  let next: TreeModel = {
    ...model,
    tasks: { ...model.tasks, [tempId]: record },
    childIds: { ...model.childIds, [tempId]: [] },
  };

  next = attach(next, parentId, tempId, args.position ?? null);
  next = resortParents(next, [parentId]);
  next = relabel(next, parentId);

  // `reconcile_after_create/2`: a new open child makes a done ancestor untrue.
  const unchecked = doneAncestorsOf(next, parentId);
  next = applyFlips(next, unchecked, false);

  const predicted = predictLineage(next, tempId);
  next = predictHeader(predicted.model);

  return {
    model: next,
    affected: unique([
      tempId,
      ...(next.childIds[parentId] ?? []),
      ...ancestorsFrom(next, parentId),
      ...unchecked,
      ...predicted.affected,
    ]),
  };
}

// --- update -----------------------------------------------------------------

export interface FieldPatch {
  title?: string;
  description?: string | null;
  priority?: Priority;
  assignee_id?: number | null;
  co_assignee_ids?: number[];
  /** Clamped to 0..100. Reaching 100 does NOT complete the task. */
  manual_progress?: number;
}

/**
 * Edits a task's own fields. Progress is clamped and nothing else: a leaf that
 * reaches 100% is not thereby done — only a status change snaps progress, and
 * only completion makes a task complete (`Tasks.update_task/3`).
 */
export function updateFields(model: TreeModel, id: number, patch: FieldPatch): OpResult {
  const record = model.tasks[id];
  if (record === undefined) return { model, affected: [] };

  const updated: TaskRecord = { ...record };
  if (patch.title !== undefined) updated.title = patch.title;
  if (patch.description !== undefined) updated.description = patch.description;
  if (patch.priority !== undefined) updated.priority = patch.priority;
  if (patch.co_assignee_ids !== undefined) updated.co_assignee_ids = [...patch.co_assignee_ids];
  if (patch.manual_progress !== undefined) {
    updated.manual_progress = Math.max(0, Math.min(100, Math.trunc(patch.manual_progress)));
  }
  if (patch.assignee_id !== undefined) {
    updated.assignee_id = patch.assignee_id;
    // Exclusivity (m02.05 12.1): primary or co-assignee, never both.
    if (patch.assignee_id !== null) {
      updated.co_assignee_ids = updated.co_assignee_ids.filter(
        (userId) => userId !== patch.assignee_id,
      );
    }
  }

  if (sameRecord(record, updated)) return { model, affected: [] };

  let next = putRecord(model, updated);
  const predicted = predictLineage(next, id);
  next = predictHeader(predicted.model);
  // A sort-key field changed, so an auto-sorted parent re-orders.
  next = resortParents(next, [record.parent_id]);

  return {
    model: next,
    affected: unique([id, ...(next.childIds[record.parent_id] ?? []), ...predicted.affected]),
  };
}

// --- completion -------------------------------------------------------------

/**
 * Completion, both directions (`cascade_complete/2`, `cascade_incomplete/2`).
 * Done cascades DOWN the whole subtree and snaps each newly-done task's manual
 * progress to 100; undone cascades down the same way and also UP, un-doing
 * every done ancestor — a parent can only be done if all its descendants are
 * (ProductSpec §9).
 */
export function setDone(model: TreeModel, id: number, done: boolean): OpResult {
  if (model.tasks[id] === undefined) return { model, affected: [] };

  const subtree = subtreeIds(model, id);
  let next = cascadeSubtree(model, id, done);
  const flips = ancestorFlips(next, id, done);
  next = applyFlips(next, flips, done);

  const predicted = predictSubtreeAndLineage(next, id);
  next = predictHeader(predicted.model);

  const parents = [
    model.tasks[id]?.parent_id,
    ...flips.map((flipId) => next.tasks[flipId]?.parent_id),
  ].filter((parentId): parentId is number => parentId !== undefined);
  next = resortParents(next, parents);

  return { model: next, affected: unique([...subtree, ...flips, ...predicted.affected]) };
}

/**
 * Which ancestors completing (or reopening) `id` would flip — the question the
 * confirm asks before the user commits to it. Changes nothing.
 */
export function wouldFlipAncestors(model: TreeModel, id: number, done: boolean): number[] {
  if (model.tasks[id] === undefined) return [];
  return ancestorFlips(cascadeSubtree(model, id, done), id, done);
}

// `id` and everything under it, flipped. `maybe_set_done_progress/2`: the snap
// to 100 and the reset to 0 fire only on a real status transition, so a leaf
// sitting at 40% that was never done keeps its 40% when it is set undone.
function cascadeSubtree(model: TreeModel, id: number, done: boolean): TreeModel {
  let next = model;
  for (const memberId of subtreeIds(model, id)) {
    const record = next.tasks[memberId];
    if (record === undefined) continue;
    const wasDone = record.status === DONE_STATUS;
    if (wasDone === done) continue;
    next = putRecord(next, {
      ...record,
      status: done ? DONE_STATUS : "open",
      done,
      manual_progress: done ? 100 : 0,
    });
  }
  return next;
}

// The ancestors a completion (or reopening) of `id` flips, against a model
// whose subtree is already flipped.
function ancestorFlips(model: TreeModel, id: number, done: boolean): number[] {
  const parentId = model.tasks[id]?.parent_id;
  if (parentId === undefined) return [];
  return done ? checkCompletedAncestors(model, parentId) : doneAncestorsOf(model, parentId);
}

function applyFlips(model: TreeModel, ids: readonly number[], done: boolean): TreeModel {
  let next = model;
  for (const id of ids) {
    const record = next.tasks[id];
    if (record === undefined) continue;
    next = putRecord(next, {
      ...record,
      status: done ? DONE_STATUS : "open",
      done,
      manual_progress: done ? 100 : 0,
    });
  }
  return next;
}

// `check_completed_ancestors/2`: climb from `parentId` while each level's whole
// child set is done, stopping at the first that is not. A level this walk has
// already decided to flip counts as done for the level above it, exactly like
// the server's `pending` substitution.
function checkCompletedAncestors(model: TreeModel, parentId: number): number[] {
  const flips: number[] = [];
  for (const id of ancestorsFrom(model, parentId)) {
    const record = model.tasks[id];
    if (record === undefined) break;
    const kids = model.childIds[id] ?? [];
    const allDone =
      kids.length > 0 &&
      kids.every((kidId) => flips.includes(kidId) || model.tasks[kidId]?.status === DONE_STATUS);
    if (!allDone || record.status === DONE_STATUS) break;
    flips.push(id);
  }
  return flips;
}

// `uncheck_done_ancestors/2`: EVERY done ancestor in the chain, not only the
// run nearest the task.
function doneAncestorsOf(model: TreeModel, parentId: number): number[] {
  return ancestorsFrom(model, parentId).filter((id) => model.tasks[id]?.status === DONE_STATUS);
}

// --- delete / restore -------------------------------------------------------

/**
 * Removes a task and its whole subtree. The records go out of the model; the
 * caller keeps them (with their slots) for the undo, and `restoreSubtree` puts
 * them back exactly where they were.
 */
export function deleteSubtree(model: TreeModel, id: number): OpResult {
  const record = model.tasks[id];
  if (record === undefined) return { model, affected: [] };

  const parentId = record.parent_id;
  const doomed = new Set(subtreeIds(model, id));

  const tasks: Record<number, TaskRecord> = { ...model.tasks };
  const childIds: Record<number, readonly number[]> = { ...model.childIds };
  for (const doomedId of doomed) {
    delete tasks[doomedId];
    delete childIds[doomedId];
  }

  let next: TreeModel = { ...model, tasks, childIds };
  const siblings = (model.childIds[parentId] ?? []).filter((siblingId) => siblingId !== id);
  next = setChildOrder(next, parentId, siblings);
  next = relabel(next, parentId);

  const predicted = predictFrom(next, parentId);
  next = predictHeader(predicted.model);

  return {
    model: next,
    affected: unique([
      ...doomed,
      ...(next.childIds[parentId] ?? []),
      ...ancestorsFrom(next, parentId),
      ...predicted.affected,
    ]),
  };
}

/**
 * Puts a deleted set back: its top record at `position` under the parent it
 * came from, everything below it in its own recorded order.
 */
export function restoreSubtree(
  model: TreeModel,
  records: readonly TaskRecord[],
  position: number | null,
): OpResult {
  if (records.length === 0) return { model, affected: [] };

  const byId = new Map(records.map((record) => [record.id, record]));
  const top = records.find((record) => !byId.has(record.parent_id));
  if (top === undefined) return { model, affected: [] };

  const tasks: Record<number, TaskRecord> = { ...model.tasks };
  const childIds: Record<number, readonly number[]> = { ...model.childIds };
  for (const record of records) {
    tasks[record.id] = record;
    if (childIds[record.id] === undefined) childIds[record.id] = [];
  }

  let next: TreeModel = { ...model, tasks, childIds };

  // Below the top, each record goes back under its own parent in slot order.
  const below = records
    .filter((record) => record.id !== top.id)
    .sort((a, b) => a.position - b.position);
  for (const record of below) {
    next = attach(next, record.parent_id, record.id, record.position);
  }
  next = attach(next, top.parent_id, top.id, position);
  next = relabel(next, top.parent_id);

  const predicted = predictLineage(next, top.id);
  next = predictHeader(predicted.model);

  return {
    model: next,
    affected: unique([
      ...records.map((record) => record.id),
      ...(next.childIds[top.parent_id] ?? []),
      ...ancestorsFrom(next, top.parent_id),
      ...predicted.affected,
    ]),
  };
}

// --- move / reorder / sort --------------------------------------------------

export interface MoveArgs {
  id: number;
  parentId: number;
  /** 0-based slot among the new siblings. `null` appends. */
  position?: number | null;
  /** An explicit sibling reorder: pins the destination to manual sort. */
  reorder?: boolean;
}

/**
 * `Tasks.move_task/3`: same Initiative (there is only one here), no cycle and
 * no self-parent. A plain reparent with no slot lands at the TOP of the new
 * parent; a reorder carries its own slot and `null` there means append
 * (the root's bottom drop-zone relies on it). Both sibling runs are renumbered,
 * both parents relabelled, and both ancestor chains recomputed and reconciled.
 */
export function moveTask(model: TreeModel, args: MoveArgs): MoveResult {
  const { id, parentId } = args;
  const record = model.tasks[id];
  if (record === undefined) return { error: "missing" };
  if (parentId !== model.rootId && model.tasks[parentId] === undefined) return { error: "missing" };
  if (parentId === id) return { error: "cycle" };
  if (subtreeIds(model, id).includes(parentId)) return { error: "cycle" };

  const oldParentId = record.parent_id;
  const reorder = args.reorder === true;
  const given = args.position ?? null;
  const position = given === null && parentId !== oldParentId && !reorder ? 0 : given;

  let next = detach(model, id);
  next = attach(next, parentId, id, position);

  // Item 16: an explicit reorder pins the destination to manual, so the
  // placement survives the next auto-resort. Must precede the resort below.
  if (reorder) next = pinManual(next, parentId);

  const wasDone = record.status === DONE_STATUS;
  const flips =
    oldParentId !== parentId ? checkCompletedAncestors(next, oldParentId) : [];
  next = applyFlips(next, flips, true);

  const destFlips = wasDone
    ? checkCompletedAncestors(next, parentId)
    : doneAncestorsOf(next, parentId);
  next = applyFlips(next, destFlips, wasDone);

  next = resortParents(next, [parentId, oldParentId]);
  next = relabel(next, parentId);
  if (oldParentId !== parentId) next = relabel(next, oldParentId);

  const fromOld = predictFrom(next, oldParentId);
  next = fromOld.model;
  const fromNew = predictFrom(next, parentId);
  next = predictHeader(fromNew.model);

  return {
    model: next,
    affected: unique([
      ...subtreeIds(next, id),
      ...(next.childIds[parentId] ?? []),
      ...(next.childIds[oldParentId] ?? []),
      ...ancestorsFrom(next, parentId),
      ...ancestorsFrom(next, oldParentId),
      ...flips,
      ...destFlips,
      ...fromOld.affected,
      ...fromNew.affected,
    ]),
  };
}

/**
 * The completion flips a move would cause in either chain
 * (`reconcile_after_move/4`), asked before the move is made. Changes nothing.
 */
export function wouldMoveFlipAncestors(model: TreeModel, args: MoveArgs): number[] {
  const record = model.tasks[args.id];
  if (record === undefined) return [];
  const oldParentId = record.parent_id;
  if (args.parentId === args.id || subtreeIds(model, args.id).includes(args.parentId)) return [];

  let after = detach(model, args.id);
  after = attach(after, args.parentId, args.id, args.position ?? null);

  const flips = oldParentId !== args.parentId ? checkCompletedAncestors(after, oldParentId) : [];
  const staged = applyFlips(after, flips, true);
  const destFlips =
    record.status === DONE_STATUS
      ? checkCompletedAncestors(staged, args.parentId)
      : doneAncestorsOf(staged, args.parentId);

  return unique([...flips, ...destFlips]);
}

/**
 * Re-keys one parent's children to `orderedIds`, ids not listed keeping their
 * relative order at the end (`Tree.reorder_children/3`). A sibling reorder
 * switches the parent to manual sort (ProductSpec §10.3.3) — the user's order
 * is the order from then on.
 */
export function reorderSiblings(
  model: TreeModel,
  parentId: number,
  orderedIds: readonly number[],
): OpResult {
  const current = model.childIds[parentId] ?? [];
  const wanted = new Map(orderedIds.map((id, index) => [id, index]));
  const fallback = wanted.size;
  const next = current
    .map((id, index) => ({ id, rank: wanted.get(id) ?? fallback, index }))
    .sort((a, b) => a.rank - b.rank || a.index - b.index)
    .map((entry) => entry.id);

  let model_ = pinManual(model, parentId);
  model_ = relabel(setChildOrder(model_, parentId, next), parentId);

  return { model: model_, affected: unique([parentId, ...next]) };
}

/**
 * Sets a branch's sort rule and re-orders its children by the RESOLVED mode, so
 * choosing "inherit" under an alphabetical ancestor re-orders immediately
 * rather than claiming an order the screen does not show (`set_sort_body/4`).
 */
export function setSort(
  model: TreeModel,
  id: number,
  mode: SortMode | null,
  reverse: boolean,
): OpResult {
  const record = model.tasks[id];
  if (record === undefined) return { model, affected: [] };

  let next = putRecord(model, { ...record, sort_mode: mode, sort_reverse: reverse });
  next = resortParents(next, [id]);

  return { model: next, affected: unique([id, ...(next.childIds[id] ?? [])]) };
}

/**
 * Makes every descendant branch inherit (`sort_mode: null`), so the whole
 * subtree follows `id`'s own rule from then on — a live link, not a stamped
 * copy — and re-sorts each of them by what they now resolve to.
 */
export function cascadeSort(model: TreeModel, id: number): OpResult {
  let next = model;
  const affected: number[] = [];

  // Top-down: each level resolves against ancestors already set to inherit.
  for (const descendantId of subtreeIds(model, id)) {
    if (descendantId === id) continue;
    const record = next.tasks[descendantId];
    if (record === undefined) continue;
    if ((next.childIds[descendantId] ?? []).length === 0) continue;
    if (record.sort_mode !== null || record.sort_reverse) {
      next = putRecord(next, { ...record, sort_mode: null, sort_reverse: false });
    }
    const before = next.childIds[descendantId] ?? [];
    next = resortParents(next, [descendantId]);
    affected.push(descendantId, ...before);
  }

  return { model: next, affected: unique(affected) };
}

// --- shared helpers ---------------------------------------------------------

function pinManual(model: TreeModel, parentId: number): TreeModel {
  const record = model.tasks[parentId];
  if (record === undefined || record.sort_mode === "manual") return model;
  return putRecord(model, { ...record, sort_mode: "manual" });
}

// The chain at and above `parentId`, which may be the system root.
function ancestorsFrom(model: TreeModel, parentId: number): number[] {
  if (parentId === model.rootId || model.tasks[parentId] === undefined) return [];
  return [parentId, ...ancestors(model, parentId)];
}

function unique(ids: readonly number[]): number[] {
  return [...new Set(ids)];
}
