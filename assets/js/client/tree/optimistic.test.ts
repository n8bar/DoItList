import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import type { TreeModel } from "./model.ts";
import { fromSnapshot } from "./model.ts";
import { addTask, setDone, updateFields } from "./ops.ts";
import { alias, begin, idle, reject, shown, succeed } from "./optimistic.ts";

//  10 ─ 11
//     └ 12
const canonical = () =>
  fromSnapshot(buildTree([{ id: 10, children: [{ id: 11 }, { id: 12 }] }]));

const done = (id: number) => (base: TreeModel) => setDone(base, id, true).model;
const progress = (id: number, value: number) => (base: TreeModel) =>
  updateFields(base, id, { manual_progress: value }).model;

const flight = (key: string, predict: (base: TreeModel) => TreeModel, tempId: number | null = null) => ({
  key,
  predict,
  tempId,
});

describe("optimistic: one prediction, then success", () => {
  it("shows the prediction at once and the canonical reply after", () => {
    const start = idle(canonical());
    const begun = begin(start, flight("a", done(11)));
    assert.equal(begun.shown.tasks[11]?.status, "done");
    assert.equal(begun.shown.tasks[10]?.progress, 50);
    // Canonical is untouched by a prediction.
    assert.equal(begun.state.canonical.tasks[11]?.status, "open");

    const landed = succeed(begun.state, "a", {
      upserts: [
        { id: 11, status: "done", done: true, manual_progress: 100, progress: 100, version: 2 },
        { id: 10, progress: 50 },
      ],
      removed: [],
    });
    assert.equal(landed.state.flights.length, 0);
    assert.equal(landed.shown, landed.state.canonical);
    assert.equal(landed.shown.tasks[11]?.version, 2);
    assert.equal(landed.shown.tasks[10]?.progress, 50);
    assert.equal(landed.createdId, null);
  });

  it("a reply that matches the prediction leaves the untouched rows' identity alone", () => {
    const start = idle(canonical());
    const begun = begin(start, flight("a", progress(11, 40)));
    const landed = succeed(begun.state, "a", {
      upserts: [{ id: 11, manual_progress: 40, progress: 40, version: 2 }, { id: 10, progress: 20 }],
      removed: [],
    });
    assert.equal(landed.shown.tasks[12], start.canonical.tasks[12]);
  });
});

describe("optimistic: two in flight", () => {
  it("first succeeds: the second prediction is rebased onto the new canonical", () => {
    const start = idle(canonical());
    const first = begin(start, flight("a", progress(11, 40)));
    const second = begin(first.state, flight("b", progress(12, 80)));
    assert.equal(second.shown.tasks[11]?.manual_progress, 40);
    assert.equal(second.shown.tasks[12]?.manual_progress, 80);
    assert.equal(second.shown.tasks[10]?.progress, 60);

    // The server clamped the first to 45 (say) — truth differs from the guess.
    const landed = succeed(second.state, "a", {
      upserts: [{ id: 11, manual_progress: 45, progress: 45, version: 2 }, { id: 10, progress: 23 }],
      removed: [],
    });
    assert.equal(landed.state.flights.map((f) => f.key).join(), "b");
    assert.equal(landed.state.canonical.tasks[11]?.manual_progress, 45);
    assert.equal(landed.state.canonical.tasks[12]?.manual_progress, 0);
    // Shown: truth for 11, the still-pending guess for 12, roll-up over both.
    assert.equal(landed.shown.tasks[11]?.manual_progress, 45);
    assert.equal(landed.shown.tasks[12]?.manual_progress, 80);
    assert.equal(landed.shown.tasks[10]?.progress, 63);
  });

  it("first rejected while the second is pending: revert keeps the second's guess", () => {
    const start = idle(canonical());
    const first = begin(start, flight("a", done(11)));
    const second = begin(first.state, flight("b", progress(12, 80)));

    const dropped = reject(second.state, "a");
    assert.equal(dropped.state.flights.map((f) => f.key).join(), "b");
    assert.equal(dropped.state.canonical, start.canonical);
    assert.equal(dropped.shown.tasks[11]?.status, "open");
    assert.equal(dropped.shown.tasks[12]?.manual_progress, 80);
    assert.equal(dropped.shown.tasks[10]?.progress, 40);

    const settled = succeed(dropped.state, "b", {
      upserts: [{ id: 12, manual_progress: 80, progress: 80, version: 2 }, { id: 10, progress: 40 }],
      removed: [],
    });
    assert.equal(settled.state.flights.length, 0);
    assert.equal(shown(settled.state), settled.state.canonical);
  });

  it("the last rejection shows canonical exactly", () => {
    const start = idle(canonical());
    const begun = begin(start, flight("a", done(11)));
    const dropped = reject(begun.state, "a");
    assert.equal(dropped.shown, start.canonical);
  });
});

describe("optimistic: an add's stand-in", () => {
  it("names the created record and keeps the stand-in's row key", () => {
    const start = idle(canonical());
    const add = (base: TreeModel) => {
      const result = addTask(base, { tempId: -3, parentId: 10, title: "New" });
      return "error" in result ? base : result.model;
    };
    const begun = begin(start, flight("a", add, -3));
    assert.deepEqual([...(begun.shown.childIds[10] ?? [])], [11, 12, -3]);

    const landed = succeed(begun.state, "a", {
      upserts: [{ id: 99, title: "New", parent_id: 10, position: 2, version: 1 }],
      removed: [],
    });
    assert.equal(landed.createdId, 99);
    assert.deepEqual([...(landed.shown.childIds[10] ?? [])], [11, 12, 99]);
    assert.equal(landed.shown.tasks[-3], undefined);

    const keys = alias(new Map(), landed.createdId, -3);
    assert.equal(keys.get(99), -3);
    assert.equal(alias(keys, null, -3), keys);
  });
});
