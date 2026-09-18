import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import { addTask, deleteSubtree, moveTask, setDone, updateFields } from "./ops.ts";
import {
  NO_PENDING,
  begin,
  recomputingIds,
  savingIds,
  scopeFor,
  settle,
} from "./pending_model.ts";

//  10 ─ 11 ─ 12
//     └ 13
//  20 ─ 21
const model = () =>
  fromSnapshot(
    buildTree([
      { id: 10, children: [{ id: 11, children: [{ id: 12 }] }, { id: 13 }] },
      { id: 20, children: [{ id: 21 }] },
    ]),
  );

const sorted = (ids: ReadonlySet<number>) => [...ids].sort((a, b) => a - b);

describe("pending_model: begin / settle", () => {
  it("is empty with nothing in flight", () => {
    assert.equal(savingIds(NO_PENDING).size, 0);
    assert.equal(recomputingIds(NO_PENDING).size, 0);
  });

  it("paints one write's scope, then clears it", () => {
    const pending = begin(NO_PENDING, "a", { saving: [12], recomputing: [11, 10] });
    assert.deepEqual(sorted(savingIds(pending)), [12]);
    assert.deepEqual(sorted(recomputingIds(pending)), [10, 11]);

    const settled = settle(pending, "a");
    assert.equal(savingIds(settled).size, 0);
    assert.equal(recomputingIds(settled).size, 0);
  });

  it("unions overlapping writes; a row stays pink until the last one settles", () => {
    let pending = begin(NO_PENDING, "a", { saving: [12], recomputing: [11, 10] });
    pending = begin(pending, "b", { saving: [13], recomputing: [10] });
    assert.deepEqual(sorted(savingIds(pending)), [12, 13]);
    assert.deepEqual(sorted(recomputingIds(pending)), [10, 11]);

    pending = settle(pending, "a");
    assert.deepEqual(sorted(savingIds(pending)), [13]);
    assert.deepEqual(sorted(recomputingIds(pending)), [10]);
  });

  it("a row one write saves is pink, not indeterminate, even if another recomputes it", () => {
    let pending = begin(NO_PENDING, "a", { saving: [12], recomputing: [11] });
    pending = begin(pending, "b", { saving: [11], recomputing: [10] });
    assert.deepEqual(sorted(savingIds(pending)), [11, 12]);
    assert.deepEqual(sorted(recomputingIds(pending)), [10]);
  });

  it("settles out of order", () => {
    let pending = begin(NO_PENDING, "a", { saving: [12], recomputing: [] });
    pending = begin(pending, "b", { saving: [21], recomputing: [20] });
    pending = settle(pending, "b");
    assert.deepEqual(sorted(savingIds(pending)), [12]);
    assert.equal(recomputingIds(pending).size, 0);
    pending = settle(pending, "a");
    assert.equal(pending.size, 0);
  });

  it("settling an unknown key changes nothing", () => {
    const pending = begin(NO_PENDING, "a", { saving: [12], recomputing: [] });
    assert.equal(settle(pending, "zzz"), pending);
    assert.equal(settle(NO_PENDING, "a"), NO_PENDING);
  });
});

describe("pending_model: scopeFor", () => {
  it("an edit saves the task and recomputes its ancestors", () => {
    const before = model();
    const op = updateFields(before, 12, { manual_progress: 50 });
    const scope = scopeFor(before, op.model, [12], op.affected);
    assert.deepEqual(scope.saving, [12]);
    assert.deepEqual([...scope.recomputing].sort((a, b) => a - b), [10, 11]);
  });

  it("a cascade saves the whole subtree and recomputes above it", () => {
    const before = model();
    const op = setDone(before, 11, true);
    const scope = scopeFor(before, op.model, [11], op.affected);
    assert.deepEqual([...scope.saving].sort((a, b) => a - b), [11, 12]);
    assert.deepEqual(scope.recomputing, [10]);
  });

  it("a move recomputes both chains and never paints the siblings", () => {
    const before = model();
    const op = moveTask(before, { id: 12, parentId: 21, position: null });
    assert.ok(!("error" in op));
    const scope = scopeFor(before, op.model, [12], op.affected);
    assert.deepEqual(scope.saving, [12]);
    assert.deepEqual([...scope.recomputing].sort((a, b) => a - b), [10, 11, 20, 21]);
  });

  it("a delete paints nothing that is gone, and recomputes what is left above", () => {
    const before = model();
    const op = deleteSubtree(before, 11);
    const scope = scopeFor(before, op.model, [11], op.affected);
    assert.deepEqual(scope.saving, []);
    assert.deepEqual(scope.recomputing, [10]);
  });

  it("an add paints its stand-in even though the affected ids leave it out", () => {
    const before = model();
    const op = addTask(before, { tempId: -7, parentId: 11, title: "New" });
    assert.ok(!("error" in op));
    // The adapter reports the affected ids without the stand-in.
    const scope = scopeFor(before, op.model, [-7], op.affected.filter((id) => id !== -7));
    assert.deepEqual(scope.saving, [-7]);
    assert.deepEqual([...scope.recomputing].sort((a, b) => a - b), [10, 11]);
  });
});
