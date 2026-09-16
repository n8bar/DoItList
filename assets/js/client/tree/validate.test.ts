import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import { InvalidTreeError, validateModel, validateSnapshot } from "./validate.ts";

const read = () =>
  buildTree([{ id: 10, children: [{ id: 11 }, { id: 12 }] }, { id: 20 }]);

const reason = (verdict: ReturnType<typeof validateSnapshot>): string =>
  verdict.ok ? "" : verdict.reason;

describe("validateSnapshot", () => {
  it("passes a tree the server actually sent", () => {
    assert.deepEqual(validateSnapshot(read()), { ok: true });
  });

  it("refuses a task whose parent is not the one it sits under", () => {
    const tree = read();
    (tree.tasks[0] as { parent_id: number }).parent_id = 77;
    assert.match(reason(validateSnapshot(tree)), /parent is 77/);
  });

  it("refuses the same id twice", () => {
    const tree = buildTree([{ id: 10 }, { id: 10 }]);
    assert.match(reason(validateSnapshot(tree)), /more than once/);
  });

  it("refuses a task claiming to be the system root", () => {
    const tree = buildTree([{ id: 1 }], { rootTaskId: 1 });
    assert.match(reason(validateSnapshot(tree)), /is the root task/);
  });

  it("refuses a sibling run with a gap in its positions", () => {
    const tree = read();
    (tree.tasks[1] as { position: number }).position = 4;
    assert.match(reason(validateSnapshot(tree)), /position 4/);
  });

  it("refuses a read with no task list at all", () => {
    const tree = { ...read(), tasks: undefined as never };
    assert.match(reason(validateSnapshot(tree)), /not a list/);
  });
});

describe("validateModel", () => {
  it("passes a model built from a good snapshot", () => {
    assert.deepEqual(validateModel(fromSnapshot(read())), { ok: true });
  });

  it("catches a child listed under a parent it does not claim", () => {
    const model = fromSnapshot(read());
    const broken = { ...model, childIds: { ...model.childIds, 20: [11] } };
    assert.match(reason(validateModel(broken)), /has more than one parent|says 10/);
  });

  it("catches a record whose parent is gone", () => {
    const model = fromSnapshot(read());
    const tasks = { ...model.tasks };
    delete tasks[10];
    assert.match(reason(validateModel({ ...model, tasks })), /has no parent 10/);
  });

  it("catches a position that disagrees with the slot", () => {
    const model = fromSnapshot(read());
    const record = model.tasks[11];
    if (record === undefined) throw new Error("fixture");
    const broken = { ...model, tasks: { ...model.tasks, 11: { ...record, position: 3 } } };
    assert.match(reason(validateModel(broken)), /position 3/);
  });

  it("catches a cycle, which detaches its members from the root", () => {
    const model = fromSnapshot(read());
    const a = model.tasks[11];
    const b = model.tasks[12];
    if (a === undefined || b === undefined) throw new Error("fixture");
    const broken = {
      ...model,
      tasks: {
        ...model.tasks,
        11: { ...a, parent_id: 12, position: 0 },
        12: { ...b, parent_id: 11, position: 0 },
      },
      childIds: { ...model.childIds, 10: [], 11: [12], 12: [11] },
    };
    assert.equal(validateModel(broken).ok, false);
  });
});

describe("InvalidTreeError", () => {
  it("carries the reason the screen has to act on", () => {
    const error = new InvalidTreeError("two roots");
    assert.equal(error.reason, "two roots");
    assert.equal(error.name, "InvalidTreeError");
    assert.match(error.message, /two roots/);
  });
});
