// Sibling sort, client-side (m04.02 item 1.4.2; ProductSpec §10.4).
//
// A port of `DoIt.Tasks.Sort.apply/3`'s comparators and of
// `DoIt.Tasks.resolve_sort/1`'s inheritance walk. The server stamps the
// canonical order; this predicts it so an auto-sorted parent re-orders under
// the user's hand instead of a frame later.
//
// `created` sorts by id, which IS insertion order for a serial primary key and
// is also the server's own tiebreak. `updated` has no client-side answer — the
// read carries no `updated_at` — so it is treated the way the engine treats any
// mode it does not know: the existing order is kept, and the server's delta
// supplies the real one. Predicting an order we cannot compute would be a
// guess dressed as an answer.

import type { SortMode } from "../api/types.ts";
import type { TaskRecord, TreeModel } from "./model.ts";

/** The modes with a comparator the client can actually evaluate. */
const COMPARABLE = new Set<string>(["alphabetical", "completion", "priority", "created"]);

export function comparable(mode: string | null): boolean {
  return mode !== null && COMPARABLE.has(mode);
}

/**
 * `id`'s effective `[mode, reverse]` for ordering ITS children: its own setting,
 * else the nearest ancestor that set one, else manual at the root.
 */
export function resolveSort(model: TreeModel, id: number): [SortMode, boolean] {
  const seen = new Set<number>();
  let current: number | undefined = id;
  while (current !== undefined && current !== model.rootId && !seen.has(current)) {
    seen.add(current);
    const record: TaskRecord | undefined = model.tasks[current];
    if (record === undefined) break;
    if (record.sort_mode !== null) return [record.sort_mode, record.sort_reverse];
    current = record.parent_id;
  }
  return ["manual", false];
}

/**
 * `ids` reordered by `mode`. Manual, and any mode with no client comparator,
 * return the list unchanged. The `id` tiebreak stays ascending in both
 * directions, so the result is fully deterministic whatever order came in.
 */
export function sortIds(
  model: TreeModel,
  ids: readonly number[],
  mode: SortMode,
  reverse: boolean,
): readonly number[] {
  if (ids.length < 2 || !comparable(mode)) return ids;

  const sorted = [...ids].sort((a, b) => {
    const left = model.tasks[a];
    const right = model.tasks[b];
    if (left === undefined || right === undefined) return a - b;
    const order = compare(left, right, mode);
    if (order === 0) return a - b;
    return reverse ? -order : order;
  });

  return sorted;
}

/** Re-sorts `parentId`'s children by its resolved mode. Manual is a no-op. */
export function sortedChildIds(model: TreeModel, parentId: number): readonly number[] {
  const ids = model.childIds[parentId] ?? [];
  const [mode, reverse] = resolveSort(model, parentId);
  return sortIds(model, ids, mode, reverse);
}

function compare(a: TaskRecord, b: TaskRecord, mode: SortMode): number {
  switch (mode) {
    case "alphabetical":
      return cmp((a.title ?? "").toLowerCase(), (b.title ?? "").toLowerCase());
    case "completion":
      return cmp(completionValue(a), completionValue(b));
    case "priority":
      return cmp(priorityRank(a.priority), priorityRank(b.priority));
    case "created":
      return cmp(a.id, b.id);
    default:
      return 0;
  }
}

function cmp(a: string | number, b: string | number): number {
  if (a === b) return 0;
  return a < b ? -1 : 1;
}

// The visible roll-up % — the same number the row's underbar shows.
function completionValue(task: TaskRecord): number {
  if (task.status === "done") return 100;
  if (typeof task.progress === "number") return task.progress;
  if (typeof task.manual_progress === "number") return task.manual_progress;
  return 0;
}

function priorityRank(priority: string): number {
  switch (priority) {
    case "high":
      return 0;
    case "normal":
      return 1;
    case "low":
      return 2;
    default:
      return 3;
  }
}
