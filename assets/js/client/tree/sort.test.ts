import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { SortMode } from "../api/types.ts";
import type { TaskSpec } from "./gen.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import { comparable, resolveSort, sortIds, sortedChildIds } from "./sort.ts";

// The system root is id 9000 here, so a fixture is free to use small task ids.
const under = (children: TaskSpec[], rest: Partial<TaskSpec> = {}) =>
  fromSnapshot(buildTree([{ id: 1000, children, ...rest }], { rootTaskId: 9000 }));

const order = (children: TaskSpec[], mode: SortMode, reverse = false) => {
  const model = under(children);
  return [...sortIds(model, model.childIds[1000] ?? [], mode, reverse)];
};

describe("comparators (a port of DoIt.Tasks.Sort.apply/3)", () => {
  it("leaves a list of one, and manual, exactly as it came in", () => {
    assert.deepEqual(order([{ id: 5 }], "alphabetical"), [5]);
    assert.deepEqual(order([{ id: 9, title: "b" }, { id: 4, title: "a" }], "manual"), [9, 4]);
  });

  it("treats a mode it does not know as manual rather than crashing", () => {
    assert.deepEqual(order([{ id: 9 }, { id: 4 }], "legacy" as SortMode), [9, 4]);
  });

  it("sorts titles case-insensitively", () => {
    const rows = [
      { id: 3, title: "banana" },
      { id: 1, title: "Apple" },
      { id: 2, title: "cherry" },
    ];
    assert.deepEqual(order(rows, "alphabetical"), [1, 3, 2]);
  });

  it("breaks a title tie by id, lowest first, whatever order came in", () => {
    const rows = [
      { id: 9, title: "same" },
      { id: 2, title: "same" },
      { id: 5, title: "same" },
    ];
    assert.deepEqual(order(rows, "alphabetical"), [2, 5, 9]);
  });

  it("orders completion ascending, with done counting as 100", () => {
    const rows: TaskSpec[] = [
      { id: 1, status: "done", manual_progress: 0 },
      { id: 2, manual_progress: 40 },
      { id: 3, manual_progress: 10 },
    ];
    assert.deepEqual(order(rows, "completion"), [3, 2, 1]);
  });

  it("orders priority high, normal, low", () => {
    const rows: TaskSpec[] = [
      { id: 1, priority: "low" },
      { id: 2, priority: "high" },
      { id: 3, priority: "normal" },
    ];
    assert.deepEqual(order(rows, "priority"), [2, 3, 1]);
  });

  it("orders created oldest first, which for a serial id is the id itself", () => {
    assert.deepEqual(order([{ id: 7 }, { id: 3 }, { id: 5 }], "created"), [3, 5, 7]);
  });

  it("leaves `updated` alone: the read carries no timestamp to sort on", () => {
    assert.equal(comparable("updated"), false);
    assert.deepEqual(order([{ id: 7 }, { id: 3 }], "updated"), [7, 3]);
  });

  it("flips the direction but never the tiebreak", () => {
    const rows = [
      { id: 1, title: "a" },
      { id: 2, title: "c" },
      { id: 3, title: "b" },
    ];
    assert.deepEqual(order(rows, "alphabetical", true), [2, 3, 1]);

    const tied = [
      { id: 9, title: "same" },
      { id: 2, title: "same" },
    ];
    assert.deepEqual(order(tied, "alphabetical", true), [2, 9]);
  });
});

describe("resolveSort", () => {
  it("falls back to manual at the root", () => {
    const model = under([{ id: 5 }]);
    assert.deepEqual(resolveSort(model, model.rootId), ["manual", false]);
    assert.deepEqual(resolveSort(model, 5), ["manual", false]);
  });

  it("uses a branch's own rule when it has one", () => {
    const model = under([{ id: 5 }], { sort_mode: "alphabetical", sort_reverse: true });
    assert.deepEqual(resolveSort(model, 1000), ["alphabetical", true]);
  });

  it("inherits from the nearest ancestor that set one, direction included", () => {
    const model = fromSnapshot(
      buildTree(
        [
          {
            id: 1,
            sort_mode: "priority",
            sort_reverse: true,
            children: [{ id: 2, children: [{ id: 3 }] }],
          },
        ],
        { rootTaskId: 9000 },
      ),
    );

    assert.deepEqual(resolveSort(model, 2), ["priority", true]);
    assert.deepEqual(resolveSort(model, 3), ["priority", true]);
  });

  it("lets a nearer branch override the one above it", () => {
    const model = fromSnapshot(
      buildTree(
        [
          {
            id: 1,
            sort_mode: "priority",
            children: [{ id: 2, sort_mode: "manual", children: [{ id: 3 }] }],
          },
        ],
        { rootTaskId: 9000 },
      ),
    );

    assert.deepEqual(resolveSort(model, 3), ["manual", false]);
  });
});

describe("sortedChildIds", () => {
  it("orders a branch's children by what that branch resolves to", () => {
    const model = under([{ id: 3, title: "c" }, { id: 1, title: "a" }], {
      sort_mode: "alphabetical",
    });
    assert.deepEqual([...sortedChildIds(model, 1000)], [1, 3]);
  });

  it("leaves a manual branch's order as the user left it", () => {
    const model = under([{ id: 3, title: "c" }, { id: 1, title: "a" }]);
    assert.deepEqual([...sortedChildIds(model, 1000)], [3, 1]);
  });
});
