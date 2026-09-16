import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { TaskSpec } from "./gen.ts";
import { buildTree } from "./gen.ts";
import type { TreeModel } from "./model.ts";
import { fromSnapshot } from "./model.ts";
import type { MoveResult, OpResult } from "./ops.ts";
import {
  addTask,
  cascadeSort,
  deleteSubtree,
  failed,
  moveTask,
  reorderSiblings,
  restoreSubtree,
  setDone,
  setSort,
  updateFields,
  wouldFlipAncestors,
  wouldMoveFlipAncestors,
} from "./ops.ts";
import { validateModel } from "./validate.ts";

const modelOf = (specs: TaskSpec[], options = {}) => fromSnapshot(buildTree(specs, options));

const order = (model: TreeModel, parentId: number) => [...(model.childIds[parentId] ?? [])];

/** Asserts an operation that can refuse did not, and unwraps it. */
const made = (result: MoveResult): OpResult => {
  assert.ok(!failed(result), failed(result) ? result.error : "");
  return result;
};

const ok = (model: TreeModel) => {
  const verdict = validateModel(model);
  assert.equal(verdict.ok, true, verdict.ok ? "" : verdict.reason);
  return model;
};

describe("addTask (ProductSpec §10.8)", () => {
  const base = () => modelOf([{ id: 10, children: [{ id: 11 }, { id: 12 }] }]);

  it("appends under a manual parent when no slot is given", () => {
    const { model } = made(addTask(base(), { tempId: -1, parentId: 10, title: "New" }));
    assert.deepEqual(order(ok(model), 10), [11, 12, -1]);
  });

  it("lands at the form's slot when one is given", () => {
    const { model } = made(addTask(base(), { tempId: -1, parentId: 10, position: 1, title: "New" }));
    assert.deepEqual(order(ok(model), 10), [11, -1, 12]);
  });

  it("goes wherever an auto-sorted parent puts it, overriding the slot", () => {
    const sorted = modelOf([
      { id: 10, sort_mode: "alphabetical", children: [{ id: 11, title: "a" }, { id: 12, title: "z" }] },
    ]);

    const { model } = made(addTask(sorted, { tempId: -1, parentId: 10, position: 0, title: "m" }));

    assert.deepEqual(order(ok(model), 10), [11, -1, 12]);
  });

  it("gives the new row a label and a depth right away", () => {
    const { model } = made(addTask(base(), { tempId: -1, parentId: 10, title: "New" }));
    assert.equal(model.tasks[-1]?.index, "1.3");
    assert.equal(model.tasks[-1]?.depth, 1);
    assert.equal(model.tasks[-1]?.priority, "normal");
  });

  it("makes a done ancestor untrue again", () => {
    const alreadyDone = modelOf([
      { id: 10, status: "done", children: [{ id: 11, status: "done" }] },
    ]);

    const { model, affected } = made(addTask(alreadyDone, { tempId: -1, parentId: 11, title: "More" }));

    assert.equal(model.tasks[10]?.status, "open");
    assert.equal(model.tasks[11]?.status, "open");
    assert.ok(affected.includes(10));
  });

  it("refuses a parent the model does not hold", () => {
    const result = addTask(base(), { tempId: -1, parentId: 999, title: "New" });
    assert.ok(failed(result) && result.error === "missing");
  });

  it("moves the ancestors' bars in the same step", () => {
    const { model } = made(
      addTask(modelOf([{ id: 10, children: [{ id: 11, manual_progress: 100 }] }]), {
        tempId: -1,
        parentId: 10,
        title: "New",
      }),
    );
    assert.equal(model.tasks[10]?.progress, 50);
    assert.equal(model.header.progress, 50);
  });
});

describe("updateFields", () => {
  const base = () => modelOf([{ id: 10, children: [{ id: 11, manual_progress: 20 }] }]);

  it("edits the fields it is given and leaves the rest alone", () => {
    const { model } = updateFields(base(), 11, { title: "Renamed", priority: "high" });
    assert.equal(model.tasks[11]?.title, "Renamed");
    assert.equal(model.tasks[11]?.priority, "high");
    assert.equal(model.tasks[11]?.manual_progress, 20);
  });

  it("clamps progress into 0..100", () => {
    assert.equal(updateFields(base(), 11, { manual_progress: 140 }).model.tasks[11]?.manual_progress, 100);
    assert.equal(updateFields(base(), 11, { manual_progress: -5 }).model.tasks[11]?.manual_progress, 0);
  });

  it("does NOT complete a leaf that reaches 100", () => {
    const { model } = updateFields(base(), 11, { manual_progress: 100 });
    assert.equal(model.tasks[11]?.status, "open");
    assert.equal(model.tasks[11]?.done, false);
    assert.equal(model.tasks[11]?.progress, 100);
  });

  it("rolls the change up the chain", () => {
    const { model, affected } = updateFields(base(), 11, { manual_progress: 60 });
    assert.equal(model.tasks[10]?.progress, 60);
    assert.deepEqual(affected.sort((a, b) => a - b), [10, 11]);
  });

  it("takes a new primary assignee off the co-assignee list", () => {
    const seeded = updateFields(base(), 11, { co_assignee_ids: [7, 8] }).model;
    const { model } = updateFields(seeded, 11, { assignee_id: 7 });
    assert.deepEqual(model.tasks[11]?.co_assignee_ids, [8]);
  });

  it("re-orders an auto-sorted parent when a sort key changes", () => {
    const sorted = modelOf([
      { id: 10, sort_mode: "alphabetical", children: [{ id: 11, title: "a" }, { id: 12, title: "b" }] },
    ]);

    const { model } = updateFields(sorted, 11, { title: "z" });

    assert.deepEqual(order(ok(model), 10), [12, 11]);
    assert.equal(model.tasks[11]?.index, "1.2");
  });

  it("changes nothing at all when the patch says nothing new", () => {
    const model = base();
    const current = model.tasks[11];
    assert.ok(current);
    const { model: next, affected } = updateFields(model, 11, { title: current.title });
    assert.equal(next, model);
    assert.deepEqual(affected, []);
  });
});

describe("setDone (ProductSpec §9)", () => {
  const family = () =>
    modelOf([
      {
        id: 10,
        children: [
          { id: 11, children: [{ id: 12 }, { id: 13 }] },
          { id: 14 },
        ],
      },
    ]);

  it("cascades down the whole subtree and snaps progress to 100", () => {
    const { model } = setDone(family(), 11, true);
    for (const id of [11, 12, 13]) {
      assert.equal(model.tasks[id]?.status, "done", `${id}`);
      assert.equal(model.tasks[id]?.manual_progress, 100, `${id}`);
      assert.equal(model.tasks[id]?.progress, 100, `${id}`);
    }
  });

  it("stops at the first ancestor whose child set is not complete", () => {
    const { model } = setDone(family(), 11, true);
    assert.equal(model.tasks[10]?.status, "open", "14 is still open");
  });

  it("completes the ancestors once the last child is done", () => {
    const half = setDone(family(), 11, true).model;
    const { model, affected } = setDone(half, 14, true);
    assert.equal(model.tasks[10]?.status, "done");
    assert.equal(model.tasks[10]?.manual_progress, 100);
    assert.ok(affected.includes(10));
  });

  it("un-does every done ancestor when a leaf is reopened", () => {
    const all = setDone(setDone(family(), 11, true).model, 14, true).model;

    const { model } = setDone(all, 12, false);

    assert.equal(model.tasks[12]?.status, "open");
    assert.equal(model.tasks[11]?.status, "open");
    assert.equal(model.tasks[10]?.status, "open");
  });

  it("does not zero a leaf that was never done", () => {
    const partial = updateFields(family(), 12, { manual_progress: 40 }).model;
    const { model } = setDone(partial, 12, false);
    assert.equal(model.tasks[12]?.manual_progress, 40);
  });

  it("names the ancestors a flip would take with it, without doing it", () => {
    const half = setDone(family(), 11, true).model;

    assert.deepEqual(wouldFlipAncestors(half, 14, true), [10]);
    assert.deepEqual(wouldFlipAncestors(family(), 12, true), []);

    const before = half;
    wouldFlipAncestors(half, 14, true);
    assert.equal(before, half, "asking changed the model");
  });

  it("names the done ancestors a reopening would un-do", () => {
    const all = setDone(setDone(family(), 11, true).model, 14, true).model;
    assert.deepEqual(wouldFlipAncestors(all, 12, false), [11, 10]);
  });
});

describe("deleteSubtree / restoreSubtree", () => {
  const base = () =>
    modelOf([{ id: 10, children: [{ id: 11 }, { id: 12, children: [{ id: 13 }] }, { id: 14 }] }]);

  it("takes the whole subtree out and renumbers what is left", () => {
    const { model } = deleteSubtree(base(), 12);

    assert.equal(model.tasks[12], undefined);
    assert.equal(model.tasks[13], undefined);
    assert.equal(model.childIds[12], undefined);
    assert.deepEqual(order(ok(model), 10), [11, 14]);
    assert.equal(model.tasks[14]?.position, 1);
    assert.equal(model.tasks[14]?.index, "1.2");
  });

  it("puts it back in the slot it came from", () => {
    const start = base();
    const doomed = [12, 13].map((id) => start.tasks[id]).filter((r) => r !== undefined);
    const after = deleteSubtree(start, 12).model;

    const { model } = restoreSubtree(after, doomed, 1);

    assert.deepEqual(order(ok(model), 10), [11, 12, 14]);
    assert.deepEqual(order(model, 12), [13]);
    assert.equal(model.tasks[13]?.index, "1.2.1");
  });

  it("recomputes the ancestors after the subtree leaves", () => {
    const start = modelOf([
      { id: 10, children: [{ id: 11, manual_progress: 0 }, { id: 12, manual_progress: 100 }] },
    ]);

    const { model } = deleteSubtree(start, 11);

    assert.equal(model.tasks[10]?.progress, 100);
    assert.equal(model.header.progress, 100);
  });

  it("does nothing for a task that is not there", () => {
    const model = base();
    assert.equal(deleteSubtree(model, 999).model, model);
    assert.equal(restoreSubtree(model, [], 0).model, model);
  });
});

describe("moveTask (Tasks.move_task/3)", () => {
  const base = () =>
    modelOf([
      { id: 10, children: [{ id: 11 }, { id: 12 }] },
      { id: 20, children: [{ id: 21 }] },
    ]);

  it("refuses to make a task its own parent", () => {
    const result = moveTask(base(), { id: 10, parentId: 10 });
    assert.ok(failed(result) && result.error === "cycle");
  });

  it("refuses to move a task into its own subtree", () => {
    const result = moveTask(base(), { id: 10, parentId: 11 });
    assert.ok(failed(result) && result.error === "cycle");
  });

  it("tells an id it does not hold apart from a refused move", () => {
    const gone = moveTask(base(), { id: 999, parentId: 10 });
    assert.ok(failed(gone) && gone.error === "missing");

    const nowhere = moveTask(base(), { id: 11, parentId: 999 });
    assert.ok(failed(nowhere) && nowhere.error === "missing");
  });

  it("lands a plain reparent at the top of the new parent", () => {
    const result = moveTask(base(), { id: 11, parentId: 20 });
    assert.ok(!failed(result));
    assert.deepEqual(order(ok(result.model), 20), [11, 21]);
    assert.deepEqual(order(result.model, 10), [12]);
  });

  it("appends when a reorder passes no slot — the root's bottom zone", () => {
    const model = base();
    const result = moveTask(model, { id: 11, parentId: model.rootId, reorder: true });
    assert.ok(!failed(result));
    assert.deepEqual(order(ok(result.model), model.rootId), [10, 20, 11]);
  });

  it("honours an explicit slot", () => {
    const result = moveTask(base(), { id: 11, parentId: 20, position: 1 });
    assert.ok(!failed(result));
    assert.deepEqual(order(ok(result.model), 20), [21, 11]);
  });

  it("relabels both runs and re-depths the moved subtree", () => {
    const deep = modelOf([
      { id: 10, children: [{ id: 11, children: [{ id: 111 }] }, { id: 12 }] },
      { id: 20 },
    ]);

    const result = moveTask(deep, { id: 11, parentId: 20 });
    assert.ok(!failed(result));

    assert.equal(result.model.tasks[11]?.index, "2.1");
    assert.equal(result.model.tasks[111]?.index, "2.1.1");
    assert.equal(result.model.tasks[111]?.depth, 2);
    assert.equal(result.model.tasks[12]?.index, "1.1");
  });

  it("pins the destination to manual on an explicit reorder", () => {
    const sorted = modelOf([
      { id: 10, sort_mode: "alphabetical", children: [{ id: 11, title: "a" }, { id: 12, title: "b" }] },
    ]);

    const result = moveTask(sorted, { id: 12, parentId: 10, position: 0, reorder: true });
    assert.ok(!failed(result));

    assert.equal(result.model.tasks[10]?.sort_mode, "manual");
    assert.deepEqual(order(ok(result.model), 10), [12, 11]);
  });

  it("lets an auto-sorted destination override the slot", () => {
    const mixed = modelOf([
      { id: 10, children: [{ id: 11, title: "m" }] },
      { id: 20, sort_mode: "alphabetical", children: [{ id: 21, title: "a" }, { id: 22, title: "z" }] },
    ]);

    const result = moveTask(mixed, { id: 11, parentId: 20, position: 0 });
    assert.ok(!failed(result));

    assert.deepEqual(order(ok(result.model), 20), [21, 11, 22]);
  });

  it("recomputes both chains", () => {
    const start = modelOf([
      { id: 10, children: [{ id: 11, manual_progress: 0 }, { id: 12, manual_progress: 100 }] },
      { id: 20, children: [{ id: 21, manual_progress: 100 }] },
    ]);

    const result = moveTask(start, { id: 11, parentId: 20 });
    assert.ok(!failed(result));

    assert.equal(result.model.tasks[10]?.progress, 100);
    assert.equal(result.model.tasks[20]?.progress, 50);
  });

  it("reconciles completion on both sides", () => {
    // 10 is done but for the incomplete 11; 20 is done through and through.
    const start = modelOf([
      { id: 10, children: [{ id: 11 }, { id: 12, status: "done" }] },
      { id: 20, status: "done", children: [{ id: 21, status: "done" }] },
    ]);

    const result = moveTask(start, { id: 11, parentId: 20 });
    assert.ok(!failed(result));

    assert.equal(result.model.tasks[10]?.status, "done", "the source chain became complete");
    assert.equal(result.model.tasks[20]?.status, "open", "the destination gained open work");
  });

  it("names the same flips before the move, without making it", () => {
    const start = modelOf([
      { id: 10, children: [{ id: 11 }, { id: 12, status: "done" }] },
      { id: 20, status: "done", children: [{ id: 21, status: "done" }] },
    ]);

    assert.deepEqual(wouldMoveFlipAncestors(start, { id: 11, parentId: 20 }).sort(), [10, 20]);
    assert.deepEqual(wouldMoveFlipAncestors(start, { id: 11, parentId: 11 }), []);
  });
});

describe("reorderSiblings (ProductSpec §10.3)", () => {
  const sorted = () =>
    modelOf([
      {
        id: 10,
        sort_mode: "alphabetical",
        children: [{ id: 11, title: "a" }, { id: 12, title: "b" }, { id: 13, title: "c" }],
      },
    ]);

  it("re-keys the run and pins the parent to manual", () => {
    const { model } = reorderSiblings(sorted(), 10, [13, 11, 12]);

    assert.equal(model.tasks[10]?.sort_mode, "manual");
    assert.deepEqual(order(ok(model), 10), [13, 11, 12]);
    assert.equal(model.tasks[13]?.index, "1.1");
  });

  it("keeps ids it was not told about, in their relative order, at the end", () => {
    const { model } = reorderSiblings(sorted(), 10, [13]);
    assert.deepEqual(order(ok(model), 10), [13, 11, 12]);
  });
});

describe("setSort and cascadeSort", () => {
  const base = () =>
    modelOf([
      {
        id: 10,
        children: [
          { id: 11, title: "z", sort_mode: "manual", children: [{ id: 111, title: "z" }, { id: 112, title: "a" }] },
          { id: 12, title: "a" },
        ],
      },
    ]);

  it("sets the rule and re-orders the children at once", () => {
    const { model, affected } = setSort(base(), 10, "alphabetical", false);

    assert.equal(model.tasks[10]?.sort_mode, "alphabetical");
    assert.deepEqual(order(ok(model), 10), [12, 11]);
    assert.ok(affected.includes(12));
  });

  it("re-orders by what a branch resolves to when it is set to inherit", () => {
    const withAncestor = setSort(base(), 10, "alphabetical", false).model;

    const { model } = setSort(withAncestor, 11, null, false);

    assert.equal(model.tasks[11]?.sort_mode, null);
    assert.deepEqual(order(ok(model), 11), [112, 111]);
  });

  it("makes the whole subtree inherit, and re-sorts each branch", () => {
    const withAncestor = setSort(base(), 10, "alphabetical", false).model;

    const { model } = cascadeSort(withAncestor, 10);

    assert.equal(model.tasks[11]?.sort_mode, null);
    assert.deepEqual(order(ok(model), 11), [112, 111]);
  });

  it("leaves leaves alone — only branches carry a rule worth cascading", () => {
    const { model } = cascadeSort(setSort(base(), 10, "alphabetical", false).model, 10);
    assert.equal(model.tasks[12]?.sort_mode, null);
  });
});
