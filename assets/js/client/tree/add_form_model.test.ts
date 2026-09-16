import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import {
  ADD_MOVE_HINT,
  addSlots,
  moveSlot,
  placeholderFor,
  placeholderText,
  placementFor,
  slotKey,
  submissionFor,
} from "./add_form_model.ts";

//  10 ─ 11
//     ─ 12 ─ 13
//  20
const model = fromSnapshot(
  buildTree([{ id: 10, children: [{ id: 11 }, { id: 12, children: [{ id: 13 }] }] }, { id: 20 }], {
    rootTaskId: 99,
  }),
);

const open = () => false;
const keys = (collapsed: (id: number) => boolean) => addSlots(model, collapsed).map(slotKey);

describe("where the add form can go", () => {
  it("offers the root slot, then each task's child and after slots, in reading order", () => {
    assert.deepEqual(keys(open), [
      "add-slot-root",
      "add-child-10",
      "add-child-11",
      "add-sibling-11",
      "add-child-12",
      "add-child-13",
      "add-sibling-13",
      "add-sibling-12",
      "add-sibling-10",
      "add-child-20",
      "add-sibling-20",
    ]);
  });

  it("skips the slots a collapsed branch hides, but keeps the branch's own", () => {
    assert.deepEqual(keys((id) => id === 12), [
      "add-slot-root",
      "add-child-10",
      "add-child-11",
      "add-sibling-11",
      "add-child-12",
      "add-sibling-12",
      "add-sibling-10",
      "add-child-20",
      "add-sibling-20",
    ]);
  });

  it("offers just the root slot for an Initiative with no tasks", () => {
    const empty = fromSnapshot(buildTree([], { rootTaskId: 99 }));
    assert.deepEqual(addSlots(empty, open).map(slotKey), ["add-slot-root"]);
  });
});

describe("walking the insertion point", () => {
  const slots = addSlots(model, open);

  it("steps down and up one slot at a time, carrying the typed title", () => {
    assert.equal(slotKey(moveSlot(slots, { kind: "root" }, 1)!), "add-child-10");
    assert.equal(slotKey(moveSlot(slots, { kind: "child", taskId: 13 }, 1)!), "add-sibling-13");
    assert.equal(slotKey(moveSlot(slots, { kind: "sibling", taskId: 13 }, -1)!), "add-child-13");
  });

  it("stops at the ends, so the caller can sound the thud", () => {
    assert.equal(moveSlot(slots, { kind: "root" }, -1), null);
    assert.equal(moveSlot(slots, { kind: "sibling", taskId: 20 }, 1), null);
  });

  it("goes nowhere from a slot that is not on the walk any more", () => {
    assert.equal(moveSlot(slots, { kind: "child", taskId: 404 }, 1), null);
  });
});

describe("where the new task lands", () => {
  it("puts a root or first-child add at the top of its list", () => {
    assert.deepEqual(placementFor(model, { kind: "root" }), { parentId: 99, position: 0 });
    assert.deepEqual(placementFor(model, { kind: "child", taskId: 12 }), {
      parentId: 12,
      position: 0,
    });
  });

  it("puts a sibling add directly after the task it follows", () => {
    assert.deepEqual(placementFor(model, { kind: "sibling", taskId: 11 }), {
      parentId: 10,
      position: 1,
    });
    assert.deepEqual(placementFor(model, { kind: "sibling", taskId: 12 }), {
      parentId: 10,
      position: 2,
    });
    assert.deepEqual(placementFor(model, { kind: "sibling", taskId: 10 }), {
      parentId: 99,
      position: 1,
    });
  });

  it("has nowhere to put a task under an anchor that is gone", () => {
    assert.equal(placementFor(model, { kind: "child", taskId: 404 }), null);
    assert.equal(placementFor(model, { kind: "sibling", taskId: 404 }), null);
  });
});

describe("the form's own wording", () => {
  it("uses the placeholders the LiveView uses, plus the move hint", () => {
    assert.equal(placeholderFor({ kind: "root" }), "New list / root task...");
    assert.equal(placeholderFor({ kind: "child", taskId: 1 }), "New subtask...");
    assert.equal(placeholderFor({ kind: "sibling", taskId: 1 }), "New task...");
    assert.equal(placeholderText({ kind: "child", taskId: 1 }), "New subtask..." + ADD_MOVE_HINT);

    const source = readFileSync(new URL("../../app.js", import.meta.url), "utf8");
    for (const text of ["New list / root task...", "New subtask...", "New task..."]) {
      assert.ok(source.includes(`"${text}"`), `app.js no longer says ${text}`);
    }
    assert.ok(source.includes(`ADD_MOVE_HINT = "${ADD_MOVE_HINT}"`));
  });
});

describe("submitting", () => {
  it("hands the caller the title and where it goes", () => {
    assert.deepEqual(submissionFor(model, { kind: "sibling", taskId: 11 }, "  Sand it  "), {
      parentId: 10,
      position: 1,
      title: "Sand it",
    });
  });

  it("refuses a blank title instead of creating an unnamed task", () => {
    assert.equal(submissionFor(model, { kind: "root" }, ""), null);
    assert.equal(submissionFor(model, { kind: "root" }, "   "), null);
  });

  it("refuses a submission whose anchor has gone", () => {
    assert.equal(submissionFor(model, { kind: "child", taskId: 404 }, "Sand it"), null);
  });
});
