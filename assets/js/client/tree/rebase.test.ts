import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiError } from "../api/client.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import { permissionsFor } from "./permissions.ts";
import {
  MOVE_CYCLE,
  NO_PERMISSION,
  TARGET_GONE,
  currentFromConflict,
  moveArgsFor,
  rebaseEdit,
  reevaluateMove,
} from "./rebase.ts";

// Root 1: 10 Cabinets [11 Doors, 12 Handles, 13 Hinges], 20 Paint.
const base = () =>
  fromSnapshot(
    buildTree(
      [
        { id: 10, title: "Cabinets", children: [{ id: 11, title: "Doors" }, { id: 12, title: "Handles" }, { id: 13, title: "Hinges" }] },
        { id: 20, title: "Paint" },
      ],
      { id: 5, rootTaskId: 1 },
    ),
  );

const owner = permissionsFor("owner");
const viewer = permissionsFor("viewer");

/** The model with task `id` (a leaf of 10) gone. */
const without = (id: number) => {
  const model = base();
  const { [id]: _gone, ...tasks } = model.tasks;
  return { ...model, tasks, childIds: { ...model.childIds, 10: model.childIds[10]!.filter((child) => child !== id) } };
};

const conflictWith = (current: unknown): ApiError => ({
  code: "conflict",
  status: 409,
  message: "stale",
  payload: { results: [{ index: 0, status: "error", error: { code: "conflict", pointer: "expected_version", current } }] },
});

describe("rebaseEdit (m04.03 4.4)", () => {
  it("sends only the user's fields, at the version the record is at now — a field they never touched stays theirs", () => {
    const op = rebaseEdit(
      { kind: "edit", id: 11, fields: { title: "Cabinet doors" } },
      { version: 4, title: "Doors", priority: "high" },
    );
    assert.deepEqual(op, { op: "update", type: "task", id: 11, data: { title: "Cabinet doors", expected_version: 4 } });
  });

  it("a same-field conflict goes again with the new version", () => {
    const op = rebaseEdit({ kind: "edit", id: 11, fields: { title: "Cabinet doors" } }, { version: 9, title: "Front doors" });
    assert.deepEqual(op?.data, { title: "Cabinet doors", expected_version: 9 });
  });

  it("is nothing when every field already reads as the user wants", () => {
    assert.equal(rebaseEdit({ kind: "edit", id: 11, fields: { title: "Doors" } }, { version: 2, title: "Doors" }), null);
  });

  it("drops the fields already so and keeps the rest; a field the reply does not carry is sent", () => {
    const op = rebaseEdit(
      { kind: "edit", id: 11, fields: { title: "Doors", description: "Oak", priority: "low" } },
      { version: 3, title: "Doors", priority: "high" },
    );
    assert.deepEqual(op?.data, { description: "Oak", priority: "low", expected_version: 3 });
  });
});

describe("currentFromConflict", () => {
  it("reads the record the reply carries", () => {
    assert.deepEqual(currentFromConflict(conflictWith({ id: 11, version: 4, title: "Doors" })), { id: 11, version: 4, title: "Doors" });
  });

  it("is null without one", () => {
    assert.equal(currentFromConflict({ code: "conflict", status: 409, message: "stale" }), null);
    assert.equal(currentFromConflict(conflictWith({ id: 11 })), null);
    assert.equal(currentFromConflict({ code: "conflict", status: 409, message: "x", payload: { results: "no" } }), null);
  });
});

describe("reevaluateMove (m04.03 4.5)", () => {
  const drop = (id: number, parentId: number, anchor: { id: number; side: "before" | "after" }, position = 1) =>
    ({ kind: "move", id, parentId, position, reorder: parentId === 10, anchor }) as const;

  it("a role that may not move anything is refused, before the tree is read", () => {
    assert.deepEqual(reevaluateMove(drop(20, 10, { id: 12, side: "after" }), base(), viewer), { kind: "refused", error: NO_PERMISSION });
  });

  it("a row or a parent that is gone is refused", () => {
    assert.deepEqual(reevaluateMove(drop(11, 10, { id: 12, side: "after" }), without(11), owner), { kind: "refused", error: TARGET_GONE });
    assert.deepEqual(reevaluateMove(drop(20, 99, { id: 12, side: "after" }), base(), owner), { kind: "refused", error: TARGET_GONE });
  });

  it("a parent inside the moved subtree is a cycle", () => {
    assert.deepEqual(reevaluateMove(drop(10, 11, { id: 11, side: "after" }), base(), owner), { kind: "refused", error: MOVE_CYCLE });
    assert.deepEqual(reevaluateMove(drop(10, 10, { id: 11, side: "after" }), base(), owner), { kind: "refused", error: MOVE_CYCLE });
  });

  it("places by the anchor as the list stands now, not the index at drop time", () => {
    // Dropped after Handles when Handles was second; Doors has since gone, so Handles is first.
    const verdict = reevaluateMove(drop(20, 10, { id: 12, side: "after" }, 2), without(11), owner);
    assert.deepEqual(verdict, { kind: "move", args: { id: 20, parentId: 10, position: 1, reorder: true } });
    // Above Hinges: Hinges' own slot.
    assert.deepEqual(reevaluateMove(drop(20, 10, { id: 13, side: "before" }, 2), base(), owner), {
      kind: "move",
      args: { id: 20, parentId: 10, position: 2, reorder: true },
    });
  });

  it("an anchor that is gone falls back to the end of the parent, or its start when the drop was above the first", () => {
    assert.deepEqual(reevaluateMove(drop(20, 10, { id: 11, side: "after" }, 1), without(11), owner), {
      kind: "move",
      args: { id: 20, parentId: 10, position: null, reorder: true },
    });
    assert.deepEqual(reevaluateMove(drop(20, 10, { id: 11, side: "before" }, 0), without(11), owner), {
      kind: "move",
      args: { id: 20, parentId: 10, position: 0, reorder: true },
    });
  });

  it("a reorder with nowhere to go is nothing", () => {
    assert.deepEqual(reevaluateMove({ kind: "reorder", id: 11, dir: "up" }, base(), owner), { kind: "nothing" });
  });

  it("a drop without an anchor keeps the slot it named", () => {
    assert.deepEqual(moveArgsFor(base(), { kind: "move", id: 20, parentId: 10, position: 1, reorder: false }), {
      id: 20,
      parentId: 10,
      position: 1,
      reorder: false,
    });
  });
});
