// The normalized client-side tree (m04.02 items 1.1.2–1.1.5, spec §9).
//
// The server sends one nested snapshot; the client keeps a flat model instead:
// records by id, and a child-order list per parent. Stable Task ids are the
// keys, so a record's identity survives every move, reorder and relabel — which
// is what lets React keep a row mounted and lets a change cost work
// proportional to itself rather than to the tree.
//
// `progress`, `index` and `depth` arrive computed by the server and are kept
// verbatim as display truth. The nested `children` arrays are NOT retained
// anywhere: `childIds` is the only statement of structure, so there is never a
// second copy of the shape to keep in step.

import type { InitiativeTree, ProgressCalc, Role, TaskNode } from "../api/types.ts";
import { InvalidTreeError, validateSnapshot } from "./validate.ts";

/** One task, exactly as `TaskNode` minus the nested children. */
export interface TaskRecord extends Omit<TaskNode, "children"> {}

/**
 * The Initiative header the screen paints above the tree. Kept on the model so
 * one store key answers "what do I show for this Initiative", without retaining
 * the nested read it came from.
 */
export interface InitiativeHeader {
  readonly id: number;
  readonly name: string;
  readonly subtitle: string | null;
  readonly role: Role;
  readonly progress: number;
  readonly unit_count: number;
  readonly version: number;
}

export interface TreeModel {
  readonly initiativeId: number;
  /** The Initiative's system root task. Never a record; only a parent key. */
  readonly rootId: number;
  readonly header: InitiativeHeader;
  readonly tasks: Readonly<Record<number, TaskRecord>>;
  /** Child order by parent id; `rootId` holds the top level. */
  readonly childIds: Readonly<Record<number, readonly number[]>>;
  readonly progressCalc: ProgressCalc;
  readonly indexStyle: string;
}

/** The header slice of a read, on its own. */
export function headerFrom(tree: InitiativeTree): InitiativeHeader {
  return {
    id: tree.id,
    name: tree.name,
    subtitle: tree.subtitle,
    role: tree.role,
    progress: tree.progress,
    unit_count: tree.unit_count,
    version: tree.version,
  };
}

/**
 * Flattens `GET /app/api/initiatives/:id` into the model.
 *
 * A snapshot that cannot describe a tree is refused here rather than half-drawn
 * — the caller decides whether to refetch (item 1.6.2); this only says no.
 */
export function fromSnapshot(tree: InitiativeTree): TreeModel {
  const verdict = validateSnapshot(tree);
  if (!verdict.ok) throw new InvalidTreeError(verdict.reason);

  const tasks: Record<number, TaskRecord> = {};
  const childIds: Record<number, number[]> = { [tree.root_task_id]: [] };

  const walk = (nodes: readonly TaskNode[], parentId: number): void => {
    const order: number[] = [];
    for (const node of nodes) {
      const { children, ...record } = node;
      tasks[node.id] = {
        ...record,
        sort_mode: record.sort_mode ?? null,
        sort_reverse: record.sort_reverse ?? false,
        updated_by: record.updated_by ?? null,
        updated_at: record.updated_at ?? null,
      };
      order.push(node.id);
      walk(children, node.id);
    }
    childIds[parentId] = order;
  };

  walk(tree.tasks, tree.root_task_id);

  return {
    initiativeId: tree.id,
    rootId: tree.root_task_id,
    header: headerFrom(tree),
    tasks,
    childIds,
    progressCalc: tree.progress_calc,
    indexStyle: tree.index_style,
  };
}

/** `id`'s children, in order. `id` may be `rootId` for the top level. */
export function children(model: TreeModel, id: number): readonly TaskRecord[] {
  const ids = model.childIds[id] ?? [];
  const out: TaskRecord[] = [];
  for (const childId of ids) {
    const record = model.tasks[childId];
    if (record !== undefined) out.push(record);
  }
  return out;
}

/** `id`'s child ids, in order — `[]` when it has none or does not exist. */
export function childIdsOf(model: TreeModel, id: number): readonly number[] {
  return model.childIds[id] ?? [];
}

/** `id`'s ancestors, nearest first. Excludes `id` and the system root. */
export function ancestors(model: TreeModel, id: number): number[] {
  const chain: number[] = [];
  const seen = new Set<number>([id]);
  let parentId = model.tasks[id]?.parent_id;
  while (parentId !== undefined && parentId !== model.rootId && !seen.has(parentId)) {
    seen.add(parentId);
    chain.push(parentId);
    parentId = model.tasks[parentId]?.parent_id;
  }
  return chain;
}

/** `id` and everything under it, pre-order. `id` may be `rootId`. */
export function subtreeIds(model: TreeModel, id: number): number[] {
  const out: number[] = [];
  const seen = new Set<number>();
  const walk = (current: number): void => {
    if (seen.has(current)) return;
    seen.add(current);
    out.push(current);
    for (const childId of model.childIds[current] ?? []) walk(childId);
  };
  walk(id);
  return id === model.rootId ? out.slice(1) : out;
}

/** Whether `id` has children — the model's own answer, not the server's `leaf`. */
export function isBranch(model: TreeModel, id: number): boolean {
  return (model.childIds[id]?.length ?? 0) > 0;
}
