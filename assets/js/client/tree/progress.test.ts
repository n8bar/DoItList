import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { InitiativeTree } from "../api/types.ts";
import type { TaskSpec } from "./gen.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import {
  average,
  computeProgress,
  doneUnitCount,
  leafValue,
  predictHeader,
  predictLineage,
  predictSubtreeAndLineage,
  unitCount,
} from "./progress.ts";

let nextId = 100;
const leaf = (manual_progress: number, status: TaskSpec["status"] = "open"): TaskSpec => ({
  id: nextId++,
  manual_progress,
  status,
});
const branch = (children: TaskSpec[], rest: Partial<TaskSpec> = {}): TaskSpec => ({
  id: nextId++,
  children,
  ...rest,
});

const modelOf = (spec: TaskSpec, calc: InitiativeTree["progress_calc"] = "leaf_average") =>
  fromSnapshot(buildTree([spec], { progressCalc: calc }));

const valueOf = (spec: TaskSpec, calc: InitiativeTree["progress_calc"] = "leaf_average") => {
  const model = modelOf(spec, calc);
  const topId = model.childIds[model.rootId]?.[0];
  return computeProgress(model, topId as number);
};

describe("leafValue", () => {
  it("uses manual progress", () => {
    assert.equal(leafValue({ status: "open", manual_progress: 42 }), 42);
  });

  it("clamps what is out of range", () => {
    assert.equal(leafValue({ status: "open", manual_progress: -5 }), 0);
    assert.equal(leafValue({ status: "open", manual_progress: 150 }), 100);
  });

  it("reads a missing value as nothing done", () => {
    assert.equal(leafValue({ status: "open", manual_progress: null as never }), 0);
  });

  it("forces done to 100 however low the number underneath", () => {
    assert.equal(leafValue({ status: "done", manual_progress: 3 }), 100);
  });
});

describe("average", () => {
  it("averages an empty list to nothing", () => {
    assert.equal(average([]), 0);
  });

  it("rounds half-up, and clamps", () => {
    assert.equal(average([33, 34]), 34);
    assert.equal(average([1, 2]), 2);
    assert.equal(average([0, 200]), 100);
  });
});

describe("leaf average (the design examples)", () => {
  it("dilutes a done sibling against a four-leaf branch", () => {
    assert.equal(valueOf(branch([leaf(100), branch([leaf(0), leaf(0), leaf(0), leaf(0)])])), 20);
  });

  it("averages sibling branches of different sizes by leaf, not by branch", () => {
    assert.equal(valueOf(branch([branch([leaf(100), leaf(100)]), branch([leaf(0)])])), 67);
  });

  it("agrees with the single-level method when the branches are flat", () => {
    assert.equal(valueOf(branch([leaf(40), leaf(80)])), 60);
  });

  it("makes a bigger subtree pull harder — decomposition IS the weighting", () => {
    const nine = Array.from({ length: 9 }, () => leaf(0));
    assert.equal(valueOf(branch([leaf(100), branch(nine)])), 10);
  });

  it("propagates grandchildren up two levels", () => {
    assert.equal(valueOf(branch([branch([leaf(0), leaf(100)]), leaf(0)])), 33);
  });

  it("ignores a branch's own manual progress", () => {
    assert.equal(valueOf(branch([leaf(0), leaf(0)], { manual_progress: 99 })), 0);
  });

  it("derives a done branch from its children rather than snapping it to 100", () => {
    assert.equal(valueOf(branch([leaf(0), leaf(0)], { status: "done" })), 0);
  });

  it("treats a childless branch as a leaf", () => {
    assert.equal(valueOf(leaf(60)), 60);
    assert.equal(valueOf(branch([leaf(42)])), 42);
  });
});

describe("single level", () => {
  it("counts each direct child as one unit however many leaves it holds", () => {
    const spec = branch([leaf(100), branch([leaf(0), leaf(0), leaf(0), leaf(0)])]);
    assert.equal(valueOf(spec, "single_level"), 50);
  });
});

describe("unit counts", () => {
  const spec = branch([leaf(100), branch([leaf(100), leaf(0)])]);

  it("counts every descendant leaf under leaf average", () => {
    const model = modelOf(spec);
    const id = model.childIds[model.rootId]?.[0] as number;
    assert.equal(unitCount(model, id), 3);
    assert.equal(doneUnitCount(model, id), 2);
  });

  it("counts each direct child once under single level", () => {
    const model = modelOf(spec, "single_level");
    const id = model.childIds[model.rootId]?.[0] as number;
    assert.equal(unitCount(model, id), 2);
    assert.equal(doneUnitCount(model, id), 1);
  });

  it("gives a childless task no units in either mode", () => {
    const model = modelOf(leaf(50));
    const id = model.childIds[model.rootId]?.[0] as number;
    assert.equal(unitCount(model, id), 0);
    assert.equal(unitCount(model, id, "single_level"), 0);
  });
});

describe("predicting a lineage", () => {
  const sample = () =>
    fromSnapshot(
      buildTree([{ id: 10, children: [{ id: 11, children: [{ id: 12, manual_progress: 0 }] }] }]),
    );

  it("recomputes the task and its ancestors, and says which moved", () => {
    const model = sample();
    const record = model.tasks[12];
    if (record === undefined) throw new Error("fixture");
    const edited = { ...model, tasks: { ...model.tasks, 12: { ...record, manual_progress: 50 } } };

    const { model: next, affected } = predictLineage(edited, 12);

    assert.equal(next.tasks[12]?.progress, 50);
    assert.equal(next.tasks[11]?.progress, 50);
    assert.equal(next.tasks[10]?.progress, 50);
    assert.deepEqual(affected.sort(), [10, 11, 12]);
  });

  it("changes nothing, and keeps identity, when the numbers already agree", () => {
    const model = sample();
    const { model: next, affected } = predictLineage(model, 12);
    assert.equal(next, model);
    assert.deepEqual(affected, []);
  });

  it("recomputes a whole subtree when a cascade moved every leaf under it", () => {
    const model = sample();
    const done = {
      ...model,
      tasks: Object.fromEntries(
        Object.entries(model.tasks).map(([id, record]) => [
          id,
          { ...record, status: "done" as const, done: true, manual_progress: 100 },
        ]),
      ),
    };

    const { model: next } = predictSubtreeAndLineage(done, 10);

    assert.equal(next.tasks[12]?.progress, 100);
    assert.equal(next.tasks[10]?.progress, 100);
  });
});

describe("the header bar", () => {
  it("is the system root's roll-up, by the same math", () => {
    const model = fromSnapshot(
      buildTree([{ id: 10, manual_progress: 100, status: "done" }, { id: 20 }]),
    );

    const next = predictHeader(model);

    assert.equal(next.header.progress, 50);
    assert.equal(next.header.unit_count, 2);
  });

  it("leaves the model alone when the bar already says the right thing", () => {
    const model = predictHeader(fromSnapshot(buildTree([{ id: 10 }])));
    assert.equal(predictHeader(model), model);
  });
});
