// Property tests over generated trees (m04.02 item 5.2).
//
// The unit suites state the rules a person thought of. These state the
// invariants that must hold whatever shape the tree happens to be and whatever
// the user does to it — run over ~200 seeded trees each, with the seed in every
// failure message so a failure is reproducible on the spot.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { GeneratedOp } from "./gen.ts";
import { buildTree, genOps, genTree, mulberry32 } from "./gen.ts";
import { relabel } from "./labels.ts";
import type { TreeModel } from "./model.ts";
import { fromSnapshot, subtreeIds } from "./model.ts";
import { applyDelta, deltaFromSnapshot } from "./delta.ts";
import {
  addTask,
  deleteSubtree,
  failed,
  moveTask,
  reorderSiblings,
  setDone,
  setSort,
  updateFields,
} from "./ops.ts";
import { validateModel } from "./validate.ts";

const RUNS = 200;

const seeds = (count = RUNS): number[] => Array.from({ length: count }, (_, i) => i + 1);

const treeFor = (seed: number, sorted = false) =>
  fromSnapshot(genTree(seed, { maxTasks: 18, maxDepth: 4, sorted }));

const live = (model: TreeModel): number[] => Object.keys(model.tasks).map(Number);

function apply(model: TreeModel, op: GeneratedOp): TreeModel {
  switch (op.kind) {
    case "add":
      if (model.tasks[op.parentId] === undefined && op.parentId !== model.rootId) return model;
      return addTask(model, {
        tempId: op.tempId,
        parentId: op.parentId,
        position: op.position,
        title: `New ${op.tempId}`,
      }).model;
    case "update":
      return updateFields(model, op.id, { manual_progress: op.manual_progress, title: op.title })
        .model;
    case "done":
      return setDone(model, op.id, op.done).model;
    case "delete":
      return deleteSubtree(model, op.id).model;
    case "move": {
      const result = moveTask(model, {
        id: op.id,
        parentId: op.parentId,
        position: op.position,
        reorder: op.reorder,
      });
      return failed(result) ? model : result.model;
    }
    case "reorder":
      return reorderSiblings(model, op.parentId, op.orderedIds).model;
    default:
      return setSort(model, op.id, op.mode, op.reverse).model;
  }
}

function runOps(seed: number, sorted = false): TreeModel {
  let model = treeFor(seed, sorted);
  for (const op of genOps(seed + 5000, live(model), model.rootId, 10)) {
    model = apply(model, op);
  }
  return model;
}

describe("whatever the shape, and whatever is done to it", () => {
  it("stays a tree: one parent each, no cycles, contiguous slots", () => {
    for (const seed of seeds()) {
      const verdict = validateModel(runOps(seed));
      assert.equal(verdict.ok, true, `seed ${seed}: ${verdict.ok ? "" : verdict.reason}`);
    }
  });

  it("stays a tree with auto-sorted branches in play too", () => {
    for (const seed of seeds(80)) {
      const verdict = validateModel(runOps(seed, true));
      assert.equal(verdict.ok, true, `seed ${seed}: ${verdict.ok ? "" : verdict.reason}`);
    }
  });

  it("keeps ids stable: an operation never renames a task it kept", () => {
    for (const seed of seeds()) {
      const before = treeFor(seed);
      const after = runOps(seed);
      for (const id of live(after)) {
        if (id < 0) continue;
        const original = before.tasks[id];
        if (original === undefined) continue;
        assert.equal(after.tasks[id]?.id, id, `seed ${seed}: task ${id} lost its id`);
      }
    }
  });

  it("labels every record exactly as a from-scratch relabel would", () => {
    for (const seed of seeds()) {
      const model = runOps(seed);
      const fresh = relabel(model, model.rootId);
      for (const id of live(model)) {
        assert.equal(
          model.tasks[id]?.index,
          fresh.tasks[id]?.index,
          `seed ${seed}: task ${id}'s label was stale`,
        );
        assert.equal(
          model.tasks[id]?.depth,
          fresh.tasks[id]?.depth,
          `seed ${seed}: task ${id}'s depth was stale`,
        );
      }
    }
  });

  it("refuses every move that would make a task its own ancestor", () => {
    for (const seed of seeds()) {
      const model = treeFor(seed);
      const random = mulberry32(seed + 77);
      const ids = live(model);
      const id = ids[Math.floor(random() * ids.length)] as number;
      for (const target of subtreeIds(model, id)) {
        const result = moveTask(model, { id, parentId: target });
        assert.ok(failed(result), `seed ${seed}: ${id} was allowed under its own ${target}`);
      }
    }
  });

  it("puts a task back where it was when the move is undone", () => {
    for (const seed of seeds()) {
      const model = treeFor(seed);
      const random = mulberry32(seed + 31);
      const ids = live(model);
      const id = ids[Math.floor(random() * ids.length)] as number;
      const record = model.tasks[id];
      if (record === undefined) continue;

      const targets = [model.rootId, ...ids].filter(
        (target) => !subtreeIds(model, id).includes(target) && target !== record.parent_id,
      );
      const target = targets[Math.floor(random() * targets.length)];
      if (target === undefined) continue;

      const moved = moveTask(model, { id, parentId: target, reorder: true, position: 0 });
      if (failed(moved)) continue;

      const back = moveTask(moved.model, {
        id,
        parentId: record.parent_id,
        position: record.position,
        reorder: true,
      });
      assert.ok(!failed(back), `seed ${seed}: the inverse move was refused`);

      for (const parentId of [model.rootId, ...ids]) {
        assert.deepEqual(
          [...(back.model.childIds[parentId] ?? [])],
          [...(model.childIds[parentId] ?? [])],
          `seed ${seed}: ${parentId}'s children did not come back`,
        );
      }
    }
  });
});

describe("applying canonical records", () => {
  it("is deterministic and idempotent for a whole re-read", () => {
    for (const seed of seeds()) {
      const model = runOps(seed);
      const delta = deltaFromSnapshot(genTree(seed + 900, { maxTasks: 18 }), model);

      const once = applyDelta(model, delta);
      const twice = applyDelta(once.model, delta);
      const again = applyDelta(model, delta);

      assert.equal(twice.model, once.model, `seed ${seed}: a replay rebuilt the model`);
      assert.deepEqual(twice.affected, [], `seed ${seed}: a replay claimed changes`);
      assert.deepEqual(
        again.model.childIds,
        once.model.childIds,
        `seed ${seed}: the same delta gave two answers`,
      );
      const verdict = validateModel(once.model);
      assert.equal(verdict.ok, true, `seed ${seed}: ${verdict.ok ? "" : verdict.reason}`);
    }
  });

  it("lands a re-read of the same tree as no change at all", () => {
    for (const seed of seeds()) {
      const read = genTree(seed, { maxTasks: 18 });
      const model = fromSnapshot(read);
      const { model: next, affected } = applyDelta(model, deltaFromSnapshot(read, model));

      assert.deepEqual(next.childIds, model.childIds, `seed ${seed}`);
      assert.deepEqual(affected, [], `seed ${seed}: an identical read claimed changes`);
    }
  });
});

describe("the generator itself", () => {
  it("only ever produces trees the validator accepts", () => {
    for (const seed of seeds()) {
      const model = fromSnapshot(genTree(seed, { maxTasks: 18, maxDepth: 4, sorted: true }));
      const verdict = validateModel(model);
      assert.equal(verdict.ok, true, `seed ${seed}: ${verdict.ok ? "" : verdict.reason}`);
      assert.ok(live(model).length > 0, `seed ${seed}: an empty tree`);
    }
  });

  it("gives the same tree for the same seed, and different ones for different seeds", () => {
    assert.deepEqual(genTree(7), genTree(7));
    assert.notDeepEqual(genTree(7), genTree(8));
  });

  it("builds a spec into a read with the labels already right", () => {
    const tree = buildTree([{ id: 5, children: [{ id: 6 }] }], { indexStyle: "outline" });
    assert.equal(tree.tasks[0]?.index, "I");
    assert.equal(tree.tasks[0]?.children[0]?.index, "I.A");
  });
});
