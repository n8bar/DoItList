// Roll-up progress, client-side (m04.02 item 1.3.2; ProductSpec §8).
//
// A port of `DoIt.Tasks.Progress`, rule for rule, for DISPLAY PREDICTION ONLY.
// The server owns roll-up truth; this exists so a checkbox the user just
// clicked moves its ancestors' bars in the same frame instead of a round trip
// later (UX_GUARDRAILS §6). When the canonical record lands it replaces what
// was predicted — see `delta.ts`.
//
// Rules:
//   * leaf → `manual_progress` clamped 0..100; `done` snaps to 100.
//   * branch (`leaf_average`, the default) → the plain average over EVERY
//     descendant leaf, so a subtree's pull is its leaf count.
//   * branch (`single_level`) → the average of its direct children's values.
//   * a childless branch is treated as a leaf.
//   * a branch's own status never feeds anyone's progress.

import type { ProgressCalc } from "../api/types.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { ancestors, subtreeIds } from "./model.ts";

/** One leaf's contribution: `done` is 100, otherwise manual progress, clamped. */
export function leafValue(task: Pick<TaskRecord, "status" | "manual_progress">): number {
  if (task.status === "done") return 100;
  return clamp(task.manual_progress);
}

/**
 * Averages roll-up values into one rounded, clamped result. Half-up rounding on
 * exact integer arithmetic, so it matches `Decimal.round(0, :half_up)` on the
 * server without floating point ever getting a vote.
 */
export function average(values: readonly number[]): number {
  if (values.length === 0) return 0;
  const sum = values.reduce((total, value) => total + value, 0);
  const rounded = Math.floor((2 * sum + values.length) / (2 * values.length));
  return clamp(rounded);
}

function clamp(value: number | null | undefined): number {
  if (typeof value !== "number" || Number.isNaN(value)) return 0;
  if (value < 0) return 0;
  if (value > 100) return 100;
  return Math.trunc(value);
}

/** Every descendant leaf's value under `id` — `id`'s own when it has no children. */
function leafValues(model: TreeModel, id: number): number[] {
  const kids = model.childIds[id] ?? [];
  if (kids.length === 0) {
    const record = model.tasks[id];
    return record === undefined ? [] : [leafValue(record)];
  }
  return kids.flatMap((childId) => leafValues(model, childId));
}

function singleLevelValue(model: TreeModel, id: number): number {
  const kids = model.childIds[id] ?? [];
  if (kids.length === 0) {
    const record = model.tasks[id];
    return record === undefined ? 0 : leafValue(record);
  }
  return average(kids.map((childId) => singleLevelValue(model, childId)));
}

/** `id`'s rolled-up value under the Initiative's progress calculation. */
export function computeProgress(model: TreeModel, id: number): number {
  if (model.progressCalc === "single_level") return singleLevelValue(model, id);
  return average(leafValues(model, id));
}

/**
 * How many units `id`'s roll-up averages over — the chevron badge's
 * denominator, and the Initiative header's when `id` is the system root. A
 * childless task has no units.
 */
export function unitCount(model: TreeModel, id: number, calc?: ProgressCalc): number {
  const kids = model.childIds[id] ?? [];
  if ((calc ?? model.progressCalc) === "single_level") return kids.length;
  return kids.reduce((total, childId) => total + leafCount(model, childId), 0);
}

/** How many of `unitCount`'s units are complete. */
export function doneUnitCount(model: TreeModel, id: number, calc?: ProgressCalc): number {
  const kids = model.childIds[id] ?? [];
  if ((calc ?? model.progressCalc) === "single_level") {
    return kids.filter((childId) => singleLevelValue(model, childId) === 100).length;
  }
  return kids.flatMap((childId) => leafValues(model, childId)).filter((value) => value === 100)
    .length;
}

function leafCount(model: TreeModel, id: number): number {
  const kids = model.childIds[id] ?? [];
  if (kids.length === 0) return 1;
  return kids.reduce((total, childId) => total + leafCount(model, childId), 0);
}

/**
 * Recomputes `progress` for `id` and every ancestor above it — the only records
 * a change under `id` can move. Returns the ids whose value actually changed;
 * untouched records keep their identity.
 */
export function predictLineage(
  model: TreeModel,
  id: number,
): { model: TreeModel; affected: number[] } {
  return recompute(model, [id, ...ancestors(model, id)]);
}

/**
 * The same recompute for `id`'s whole subtree as well as its lineage — what a
 * cascade down (`setDone`) needs, since every descendant's own value moved too.
 */
export function predictSubtreeAndLineage(
  model: TreeModel,
  id: number,
): { model: TreeModel; affected: number[] } {
  // Deepest first, so a branch is recomputed after the children it averages.
  const subtree = subtreeIds(model, id).reverse();
  return recompute(model, [...subtree, ...ancestors(model, id)]);
}

/**
 * Recomputes `progress` up from `parentId` — the same walk as `predictLineage`
 * for a parent that may be the system root (a deletion's old parent, say).
 */
export function predictFrom(
  model: TreeModel,
  parentId: number,
): { model: TreeModel; affected: number[] } {
  if (parentId === model.rootId) return { model, affected: [] };
  return predictLineage(model, parentId);
}

/**
 * The Initiative header's own bar: the system root's roll-up, by the same math
 * end to end (ProductSpec §8). Server truth still replaces it on the next
 * delta; this keeps the top of the screen honest in the meantime.
 */
export function predictHeader(model: TreeModel): TreeModel {
  const progress = computeProgress(model, model.rootId);
  const units = unitCount(model, model.rootId);
  if (model.header.progress === progress && model.header.unit_count === units) return model;
  return { ...model, header: { ...model.header, progress, unit_count: units } };
}

function recompute(model: TreeModel, ids: readonly number[]): {
  model: TreeModel;
  affected: number[];
} {
  const changes: Record<number, TaskRecord> = {};
  const affected: number[] = [];
  let current = model;

  for (const id of ids) {
    const record = current.tasks[id];
    if (record === undefined) continue;
    const progress = computeProgress(current, id);
    if (progress === record.progress) continue;
    const updated = { ...record, progress };
    changes[id] = updated;
    affected.push(id);
    // Each level reads the level below, so the change has to be visible.
    current = { ...current, tasks: { ...current.tasks, [id]: updated } };
  }

  if (affected.length === 0) return { model, affected: [] };
  return { model: { ...model, tasks: { ...model.tasks, ...changes } }, affected };
}
