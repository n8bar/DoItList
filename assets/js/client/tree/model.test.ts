import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import {
  ancestors,
  childIdsOf,
  children,
  fromSnapshot,
  headerFrom,
  isBranch,
  subtreeIds,
} from "./model.ts";
import { InvalidTreeError } from "./validate.ts";

const read = () =>
  buildTree([
    { id: 10, title: "Cabinets", children: [{ id: 11 }, { id: 12, children: [{ id: 13 }] }] },
    { id: 20, title: "Worktop" },
  ]);

describe("fromSnapshot", () => {
  it("keys every task by id, with the child order per parent", () => {
    const model = fromSnapshot(read());

    assert.deepEqual(Object.keys(model.tasks).map(Number).sort(), [10, 11, 12, 13, 20]);
    assert.deepEqual(childIdsOf(model, model.rootId), [10, 20]);
    assert.deepEqual(childIdsOf(model, 10), [11, 12]);
    assert.deepEqual(childIdsOf(model, 12), [13]);
    assert.deepEqual(childIdsOf(model, 13), []);
  });

  it("keeps the server's progress, index and depth verbatim", () => {
    const model = fromSnapshot(read());

    assert.equal(model.tasks[12]?.index, "1.2");
    assert.equal(model.tasks[13]?.index, "1.2.1");
    assert.equal(model.tasks[13]?.depth, 2);
    assert.equal(model.tasks[10]?.depth, 0);
  });

  it("retains no nested children anywhere", () => {
    const model = fromSnapshot(read());
    for (const record of Object.values(model.tasks)) {
      assert.equal("children" in record, false, `${record.id} still carries a nested tree`);
    }
  });

  it("defaults a sort pair the server has not started sending", () => {
    const tree = read();
    const first = tree.tasks[0] as unknown as Record<string, unknown>;
    delete first["sort_mode"];
    delete first["sort_reverse"];

    const model = fromSnapshot(tree);

    assert.equal(model.tasks[10]?.sort_mode, null);
    assert.equal(model.tasks[10]?.sort_reverse, false);
  });

  it("carries the header and the Initiative's own settings", () => {
    const model = fromSnapshot(read());

    assert.deepEqual(model.header, headerFrom(read()));
    assert.equal(model.progressCalc, "leaf_average");
    assert.equal(model.indexStyle, "numerical");
    assert.equal(model.initiativeId, 12);
    assert.equal(model.rootId, 1);
  });

  it("refuses a snapshot that cannot be a tree, and says why", () => {
    const tree = read();
    (tree.tasks[0] as { parent_id: number }).parent_id = 999;

    assert.throws(
      () => fromSnapshot(tree),
      (error: unknown) => error instanceof InvalidTreeError && error.reason.includes("999"),
    );
  });
});

describe("reading the model", () => {
  it("hands back children in order, as records", () => {
    const model = fromSnapshot(read());
    assert.deepEqual(
      children(model, 10).map((record) => record.id),
      [11, 12],
    );
    assert.deepEqual(children(model, 20), []);
  });

  it("walks ancestors nearest first, stopping short of the system root", () => {
    const model = fromSnapshot(read());
    assert.deepEqual(ancestors(model, 13), [12, 10]);
    assert.deepEqual(ancestors(model, 10), []);
  });

  it("walks a subtree pre-order, including the task itself", () => {
    const model = fromSnapshot(read());
    assert.deepEqual(subtreeIds(model, 10), [10, 11, 12, 13]);
    assert.deepEqual(subtreeIds(model, 13), [13]);
  });

  it("walks the whole tree from the system root, which is not a task", () => {
    const model = fromSnapshot(read());
    assert.deepEqual(subtreeIds(model, model.rootId), [10, 11, 12, 13, 20]);
  });

  it("answers branch or leaf from the child order, not the server's flag", () => {
    const model = fromSnapshot(read());
    assert.equal(isBranch(model, 10), true);
    assert.equal(isBranch(model, 13), false);
    assert.equal(isBranch(model, 999), false);
  });
});
