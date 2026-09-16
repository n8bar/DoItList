// Is this actually a tree? (m04.02 items 1.6.1–1.6.2)
//
// A snapshot that cannot describe a tree — a parent that is not there, two
// roots, a cycle, a repeated id, a sibling run that skips a slot — is a bug on
// one side or a truncated response, and the honest answer is to refuse it, not
// to draw three quarters of it and let the user act on the rest. This module
// only says yes or no and why; who refetches, and how often, is the screen's
// call (item 1.6.2).

import type { InitiativeTree, TaskNode } from "../api/types.ts";
import type { TreeModel } from "./model.ts";

export type Verdict = { ok: true } | { ok: false; reason: string };

const OK: Verdict = { ok: true };

const no = (reason: string): Verdict => ({ ok: false, reason });

/**
 * What the user is told when a read could not be made into a tree twice
 * running. Shared by the screen and the live refresh so both say one thing.
 */
export const UNUSABLE_TREE_NOTICE =
  "This Initiative did not arrive in one piece, twice running. What is on screen may be out of date — reload, and say something if it keeps happening.";

/** The line shown in place of the tree, next to Try again. */
export const UNUSABLE_TREE_MESSAGE = "This Initiative did not arrive in one piece.";

/** Thrown by `fromSnapshot` when the read cannot be a tree. */
export class InvalidTreeError extends Error {
  readonly reason: string;

  constructor(reason: string) {
    super(`invalid tree: ${reason}`);
    this.name = "InvalidTreeError";
    this.reason = reason;
  }
}

/** Checks the nested read before it is flattened. */
export function validateSnapshot(tree: InitiativeTree): Verdict {
  if (!Array.isArray(tree.tasks)) return no("tasks is not a list");
  if (typeof tree.root_task_id !== "number") return no("no root task id");

  const seen = new Set<number>([tree.root_task_id]);

  const walk = (nodes: readonly TaskNode[], parentId: number): Verdict => {
    for (const [index, node] of nodes.entries()) {
      if (typeof node?.id !== "number") return no("a task has no id");
      if (node.id === tree.root_task_id) return no(`task ${node.id} is the root task`);
      if (seen.has(node.id)) return no(`task ${node.id} appears more than once`);
      seen.add(node.id);
      if (node.parent_id !== parentId) {
        return no(`task ${node.id} says its parent is ${node.parent_id}, but it sits under ${parentId}`);
      }
      if (node.position !== index) {
        return no(`task ${node.id} is at slot ${index} but says position ${node.position}`);
      }
      const kids = node.children ?? [];
      if (!Array.isArray(kids)) return no(`task ${node.id} has no child list`);
      const verdict = walk(kids, node.id);
      if (!verdict.ok) return verdict;
    }
    return OK;
  };

  return walk(tree.tasks, tree.root_task_id);
}

/** The same rules, against a model an operation just produced. */
export function validateModel(model: TreeModel): Verdict {
  const ids = Object.keys(model.tasks).map(Number);

  for (const id of ids) {
    const record = model.tasks[id];
    if (record === undefined) continue;
    if (record.id !== id) return no(`record ${id} carries id ${record.id}`);
    if (id === model.rootId) return no(`task ${id} is the root task`);
    const parentId = record.parent_id;
    if (parentId !== model.rootId && model.tasks[parentId] === undefined) {
      return no(`task ${id} has no parent ${parentId}`);
    }
    const siblings = model.childIds[parentId] ?? [];
    if (!siblings.includes(id)) return no(`task ${id} is not among ${parentId}'s children`);
  }

  // Exactly one parent each, positions contiguous and in order.
  const claimed = new Set<number>();
  for (const key of Object.keys(model.childIds)) {
    const parentId = Number(key);
    if (parentId !== model.rootId && model.tasks[parentId] === undefined) {
      return no(`child order kept for missing task ${parentId}`);
    }
    const order = model.childIds[parentId] ?? [];
    for (const [index, childId] of order.entries()) {
      const record = model.tasks[childId];
      if (record === undefined) return no(`${parentId} lists missing task ${childId}`);
      if (record.parent_id !== parentId) {
        return no(`task ${childId} is listed under ${parentId} but says ${record.parent_id}`);
      }
      if (claimed.has(childId)) return no(`task ${childId} has more than one parent`);
      claimed.add(childId);
      if (record.position !== index) {
        return no(`task ${childId} is at slot ${index} but says position ${record.position}`);
      }
    }
  }

  // Everything must hang off the root, which also rules out a detached cycle.
  const reached = new Set<number>();
  const stack: number[] = [...(model.childIds[model.rootId] ?? [])];
  while (stack.length > 0) {
    const id = stack.pop() as number;
    if (reached.has(id)) return no(`task ${id} is reachable twice`);
    reached.add(id);
    for (const childId of model.childIds[id] ?? []) stack.push(childId);
  }
  if (reached.size !== ids.length) return no("some tasks do not hang off the root");

  return OK;
}
