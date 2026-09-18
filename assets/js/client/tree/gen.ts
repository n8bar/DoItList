// Trees to test with (m04.02 item 5.2.1).
//
// Two jobs, one subject: `buildTree` turns a compact nested spec into a real
// `InitiativeTree` so a unit test can state the shape it means in three lines,
// and `genTree` makes random valid ones from a seed so the property tests can
// try shapes nobody thought to write down.
//
// Seeded on purpose, and with no new dependency: a failure names the seed that
// produced it, and re-running that seed reproduces the exact tree.

import type { InitiativeTree, Priority, SortMode, TaskEditor, TaskNode, TaskStatus } from "../api/types.ts";
import { label } from "./labels.ts";

/** A deterministic PRNG (mulberry32). Same seed, same sequence, everywhere. */
export function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export interface TaskSpec {
  id: number;
  title?: string;
  description?: string | null;
  status?: TaskStatus;
  manual_progress?: number;
  /** The rolled-up number the server would send. Defaults to the leaf value. */
  progress?: number;
  priority?: Priority;
  assignee_id?: number | null;
  co_assignee_ids?: number[];
  sort_mode?: SortMode | null;
  sort_reverse?: boolean;
  updated_by?: TaskEditor | null;
  updated_at?: string | null;
  children?: TaskSpec[];
}

export interface TreeOptions {
  id?: number;
  name?: string;
  rootTaskId?: number;
  indexStyle?: string;
  progressCalc?: InitiativeTree["progress_calc"];
}

/** A whole read built from a nested spec, with index, depth and position right. */
export function buildTree(specs: readonly TaskSpec[], options: TreeOptions = {}): InitiativeTree {
  const indexStyle = options.indexStyle ?? "numerical";
  const rootTaskId = options.rootTaskId ?? 1;

  const node = (
    spec: TaskSpec,
    parentId: number,
    positions: readonly number[],
    depth: number,
  ): TaskNode => {
    const position = positions[positions.length - 1] ?? 0;
    const status = spec.status ?? "open";
    const children = (spec.children ?? []).map((child, index) =>
      node(child, spec.id, [...positions, index], depth + 1),
    );
    return {
      id: spec.id,
      title: spec.title ?? `Task ${spec.id}`,
      description: spec.description ?? null,
      index: label(positions, indexStyle),
      position,
      parent_id: parentId,
      depth,
      progress: spec.progress ?? (status === "done" ? 100 : (spec.manual_progress ?? 0)),
      manual_progress: spec.manual_progress ?? 0,
      status,
      done: status === "done",
      leaf: children.length === 0,
      priority: spec.priority ?? "normal",
      assignee_id: spec.assignee_id ?? null,
      co_assignee_ids: spec.co_assignee_ids ?? [],
      comment_count: 0,
      cross_references: [],
      referenced_by: [],
      sort_mode: spec.sort_mode ?? null,
      sort_reverse: spec.sort_reverse ?? false,
      updated_by: spec.updated_by ?? null,
      updated_at: spec.updated_at ?? null,
      version: 1,
      children,
    };
  };

  return {
    id: options.id ?? 12,
    name: options.name ?? "Kitchen",
    subtitle: null,
    role: "owner",
    progress: 0,
    progress_calc: options.progressCalc ?? "leaf_average",
    unit_count: 0,
    index_style: indexStyle,
    root_task_id: rootTaskId,
    version: 1,
    tasks: specs.map((spec, index) => node(spec, rootTaskId, [index], 0)),
  };
}

export interface GenOptions {
  maxTasks?: number;
  maxDepth?: number;
  indexStyle?: string;
  progressCalc?: InitiativeTree["progress_calc"];
  /** Let some branches carry an explicit sort rule. */
  sorted?: boolean;
}

const PRIORITIES: readonly Priority[] = ["high", "normal", "low"];
const STATUSES: readonly TaskStatus[] = ["open", "in_progress", "done"];
const SORT_MODES: readonly SortMode[] = ["manual", "alphabetical", "completion", "priority"];

/** A random but always-valid read: ids are unique and ascending from 100. */
export function genTree(seed: number, options: GenOptions = {}): InitiativeTree {
  const random = mulberry32(seed);
  const maxTasks = options.maxTasks ?? 24;
  const maxDepth = options.maxDepth ?? 4;

  let remaining = Math.max(1, Math.floor(random() * maxTasks) + 1);
  let nextId = 100;

  const pick = <T,>(values: readonly T[]): T => values[Math.floor(random() * values.length)] as T;

  const grow = (depth: number): TaskSpec[] => {
    const width = remaining === 0 ? 0 : Math.floor(random() * 4);
    const specs: TaskSpec[] = [];
    for (let i = 0; i < width && remaining > 0; i += 1) {
      remaining -= 1;
      const spec: TaskSpec = {
        id: nextId,
        title: `T${nextId} ${pick(["alpha", "Beta", "gamma", "Delta"])}`,
        status: pick(STATUSES),
        manual_progress: Math.floor(random() * 101),
        priority: pick(PRIORITIES),
      };
      nextId += 1;
      if (options.sorted === true && random() < 0.25) {
        spec.sort_mode = pick(SORT_MODES);
        spec.sort_reverse = random() < 0.5;
      }
      if (depth < maxDepth) {
        const kids = grow(depth + 1);
        if (kids.length > 0) spec.children = kids;
      }
      specs.push(spec);
    }
    return specs;
  };

  // At least one top-level task, so a generated tree is never empty.
  let roots = grow(0);
  if (roots.length === 0) {
    roots = [{ id: nextId, title: "T only" }];
  }

  const built: TreeOptions = {
    ...(options.indexStyle === undefined ? {} : { indexStyle: options.indexStyle }),
    ...(options.progressCalc === undefined ? {} : { progressCalc: options.progressCalc }),
  };

  return buildTree(roots, built);
}

export type GeneratedOp =
  | { kind: "add"; parentId: number; tempId: number; position: number | null }
  | { kind: "update"; id: number; manual_progress: number; title: string }
  | { kind: "done"; id: number; done: boolean }
  | { kind: "delete"; id: number }
  | { kind: "move"; id: number; parentId: number; position: number | null; reorder: boolean }
  | { kind: "reorder"; parentId: number; orderedIds: number[] }
  | { kind: "sort"; id: number; mode: SortMode; reverse: boolean };

/**
 * A random sequence of operations over `ids` — deliberately including ones that
 * cannot be applied (a move into a descendant, an id already deleted), since
 * refusing those cleanly is part of what the properties check.
 */
export function genOps(
  seed: number,
  ids: readonly number[],
  rootId: number,
  count: number,
): GeneratedOp[] {
  const random = mulberry32(seed);
  const pool = [rootId, ...ids];
  const pick = <T,>(values: readonly T[]): T => values[Math.floor(random() * values.length)] as T;
  const ops: GeneratedOp[] = [];
  let tempId = -1;

  for (let i = 0; i < count; i += 1) {
    const roll = random();
    if (roll < 0.2) {
      ops.push({
        kind: "add",
        parentId: pick(pool),
        tempId,
        position: random() < 0.5 ? null : Math.floor(random() * 4),
      });
      tempId -= 1;
    } else if (roll < 0.35) {
      const id = pick(ids);
      ops.push({ kind: "update", id, manual_progress: Math.floor(random() * 140) - 20, title: `R${i}` });
    } else if (roll < 0.5) {
      ops.push({ kind: "done", id: pick(ids), done: random() < 0.5 });
    } else if (roll < 0.58) {
      ops.push({ kind: "delete", id: pick(ids) });
    } else if (roll < 0.82) {
      ops.push({
        kind: "move",
        id: pick(ids),
        parentId: pick(pool),
        position: random() < 0.5 ? null : Math.floor(random() * 4),
        reorder: random() < 0.5,
      });
    } else if (roll < 0.92) {
      ops.push({ kind: "reorder", parentId: pick(pool), orderedIds: shuffle(ids, random) });
    } else {
      ops.push({ kind: "sort", id: pick(ids), mode: pick(SORT_MODES), reverse: random() < 0.5 });
    }
  }

  return ops;
}

function shuffle(ids: readonly number[], random: () => number): number[] {
  const out = [...ids];
  for (let i = out.length - 1; i > 0; i -= 1) {
    const j = Math.floor(random() * (i + 1));
    const a = out[i] as number;
    const b = out[j] as number;
    out[i] = b;
    out[j] = a;
  }
  return out;
}
