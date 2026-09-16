import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import {
  firstUrlWrite,
  initialSelection,
  revealPlan,
  searchWithTask,
  taskParam,
} from "./reveal_model.ts";
import { keptSelection } from "./selection_model.ts";

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

describe("which task an Initiative screen opens with", () => {
  // Selection is per Initiative. `ui.selectedTaskId` is one flat field that
  // outlives the screen, so a task selected in Initiative A is still sitting
  // there when Initiative B mounts — and B must not inherit it.
  it("prefers the task the link names", () => {
    assert.equal(initialSelection(model(), 13, 4321), 13);
  });

  it("drops a selection that belongs to another Initiative", () => {
    assert.equal(initialSelection(model(), null, 4321), null);
  });

  it("keeps a selection this tree does have", () => {
    assert.equal(initialSelection(model(), null, 12), 12);
  });

  it("falls back to a kept selection when the link names nothing real", () => {
    assert.equal(initialSelection(model(), 4321, 12), 12);
  });

  it("opens with nothing when neither the link nor the store fits", () => {
    assert.equal(initialSelection(model(), 4321, 4322), null);
  });
});

describe("the first write to the address bar", () => {
  it("writes nothing when the link already names the resolved task", () => {
    assert.equal(firstUrlWrite("?task=13", 13), null);
  });

  it("clears a parameter naming a task this tree does not have", () => {
    assert.equal(firstUrlWrite("?task=4321", null), "");
  });

  it("leaves the rest of the query alone when it does write", () => {
    assert.equal(firstUrlWrite("?from=bell&task=4321", 12), "?from=bell&task=12");
  });
});

describe("arriving at a deep link with a task already selected elsewhere", () => {
  // The re-review's scenario, end to end in the pure decisions: task 4321 is
  // selected (Initiative A), the user follows `?task=13` into this tree.
  it("selects the link's task, keeps the parameter, and writes nothing on the way in", () => {
    const tree = model();
    const stale = 4321;

    const resolved = initialSelection(tree, taskParam("?task=13"), stale);
    assert.equal(resolved, 13);

    // No strip-then-restore pair: the one parameter we own already says 13.
    assert.equal(firstUrlWrite("?task=13", resolved), null);

    // Reveal opens 12, the one collapsed branch between the root and 13.
    const plan = revealPlan(tree, resolved, closedSet(12));
    assert.deepEqual(plan.expand, [12]);
    assert.equal(plan.select, 13);

    // And pruning, reading the RESOLVED value rather than the stale one it
    // would have captured, leaves the reveal standing.
    assert.equal(keptSelection(resolved, [10, 11, 12, 13, 20], true), 13);
    // The stale id is what the old wiring saw, and it would have cleared it.
    assert.equal(keptSelection(stale, [10, 11, 12, 13, 20], true), null);
  });
});
