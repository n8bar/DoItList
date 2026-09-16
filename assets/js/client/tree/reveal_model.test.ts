import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import { revealPlan, searchWithTask, taskParam } from "./reveal_model.ts";

const model = () =>
  fromSnapshot(
    buildTree(
      [
        { id: 10, children: [{ id: 11 }, { id: 12, children: [{ id: 13 }] }] },
        { id: 20 },
      ],
      { rootTaskId: 99 },
    ),
  );

const open = () => false;
const closedSet = (...ids: number[]) => (id: number) => ids.includes(id);

describe("the task a link names", () => {
  it("reads the task parameter", () => {
    assert.equal(taskParam("?task=13"), 13);
    assert.equal(taskParam("task=13"), 13);
    assert.equal(taskParam("?from=bell&task=13"), 13);
  });

  it("ignores anything that is not a task id", () => {
    assert.equal(taskParam(""), null);
    assert.equal(taskParam("?task="), null);
    assert.equal(taskParam("?task=nope"), null);
    assert.equal(taskParam("?task=0"), null);
    assert.equal(taskParam("?task=-4"), null);
    assert.equal(taskParam("?task=1.5"), null);
  });
});

describe("what revealing a task takes", () => {
  it("names every collapsed ancestor and then the task itself", () => {
    assert.deepEqual(revealPlan(model(), 13, closedSet(10, 12)), {
      expand: [10, 12],
      select: 13,
    });
  });

  it("still selects and scrolls when nothing needs expanding", () => {
    assert.deepEqual(revealPlan(model(), 13, open), { expand: [], select: 13 });
  });

  it("does nothing for a task this Initiative does not hold", () => {
    assert.deepEqual(revealPlan(model(), 404, closedSet(10)), { expand: [], select: null });
  });
});

describe("keeping the address bar in step", () => {
  it("adds the task without disturbing the rest of the query", () => {
    assert.equal(searchWithTask("?from=bell", 13), "?from=bell&task=13");
    assert.equal(searchWithTask("?task=9&from=bell", 13), "?task=13&from=bell");
  });

  it("drops only the task when the selection is cleared", () => {
    assert.equal(searchWithTask("?from=bell&task=9", null), "?from=bell");
    assert.equal(searchWithTask("?task=9", null), "");
    assert.equal(searchWithTask("", null), "");
  });

  it("names the parameter the LiveView's deep link names", () => {
    const live = readFileSync(
      new URL("../../../../lib/doit_web/live/initiative_workspace_live.ex", import.meta.url),
      "utf8",
    );
    assert.ok(
      live.includes('"task" => '),
      "the workspace no longer reads a `task` parameter",
    );
  });
});
