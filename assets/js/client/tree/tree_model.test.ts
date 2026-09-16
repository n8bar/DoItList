import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";
import type { CollapseStore } from "./tree_model.ts";
import {
  TREE_WIDTH_FLOOR_PX,
  collapseKey,
  isVisible,
  readCollapsed,
  seedCollapsed,
  treeMinWidth,
  treeMinWidthStyle,
  visibleIds,
  visibleRows,
  branchesToOpen,
  writeCollapsed,
} from "./tree_model.ts";

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

class FakeStore implements CollapseStore {
  readonly entries = new Map<string, string>();
  getItem(key: string) {
    return this.entries.get(key) ?? null;
  }
  setItem(key: string, value: string) {
    this.entries.set(key, value);
  }
}

describe("the rows on screen", () => {
  it("walks the tree in reading order, depth by depth", () => {
    assert.deepEqual(visibleRows(model(), open), [
      { id: 10, depth: 0 },
      { id: 11, depth: 1 },
      { id: 12, depth: 1 },
      { id: 13, depth: 2 },
      { id: 20, depth: 0 },
    ]);
  });

  it("keeps a collapsed branch itself and hides everything under it", () => {
    assert.deepEqual(visibleIds(model(), closedSet(10)), [10, 20]);
    assert.deepEqual(visibleIds(model(), closedSet(12)), [10, 11, 12, 20]);
  });

  it("reports whether a task is reachable without expanding anything", () => {
    assert.equal(isVisible(model(), closedSet(10), 13), false);
    assert.equal(isVisible(model(), closedSet(12), 12), true);
    assert.equal(isVisible(model(), open, 13), true);
    assert.equal(isVisible(model(), open, 404), false);
  });

  it("shows an empty Initiative as no rows at all, not as a missing root", () => {
    const empty = fromSnapshot(buildTree([], { rootTaskId: 99 }));
    assert.deepEqual(visibleRows(empty, open), []);
  });
});

describe("where a branch's open state is kept", () => {
  it("uses the key the LiveView's CollapseToggle hook uses", () => {
    assert.equal(collapseKey(12, 345), "phx:collapse:12:345");
    const hook = readFileSync(new URL("../../app.js", import.meta.url), "utf8");
    assert.ok(
      hook.includes("`phx:collapse:${this.el.dataset.initiativeId}:${this.el.dataset.taskId}`"),
      "app.js no longer builds the collapse key this way",
    );
  });

  it("reads only \"1\" as collapsed, so an unseen branch opens", () => {
    const store = new FakeStore();
    assert.equal(readCollapsed(store, 12, 345), false);

    writeCollapsed(store, 12, 345, true);
    assert.equal(store.getItem("phx:collapse:12:345"), "1");
    assert.equal(readCollapsed(store, 12, 345), true);

    writeCollapsed(store, 12, 345, false);
    assert.equal(store.getItem("phx:collapse:12:345"), "0");
    assert.equal(readCollapsed(store, 12, 345), false);
  });

  it("does not depend on the branch having children", () => {
    // A branch that loses its last child keeps whatever the user set.
    const store = new FakeStore();
    writeCollapsed(store, 12, 345, true);
    const childless = fromSnapshot(buildTree([{ id: 345 }], { rootTaskId: 99 }));

    assert.equal(readCollapsed(store, 12, 345), true);
    assert.deepEqual(visibleIds(childless, (id) => readCollapsed(store, 12, id)), [345]);
  });

  it("treats a store that throws, or none at all, as everything open", () => {
    const hostile: CollapseStore = {
      getItem() {
        throw new Error("site data blocked");
      },
      setItem() {
        throw new Error("site data blocked");
      },
    };

    assert.equal(readCollapsed(hostile, 1, 2), false);
    assert.doesNotThrow(() => writeCollapsed(hostile, 1, 2, true));
    assert.equal(readCollapsed(null, 1, 2), false);
    assert.doesNotThrow(() => writeCollapsed(null, 1, 2, true));
  });
});

describe("how wide the tree has to be", () => {
  it("is the deepest visible indent plus a whole row", () => {
    assert.equal(treeMinWidth([0, 24, 48]), 48 + TREE_WIDTH_FLOOR_PX);
    assert.equal(treeMinWidthStyle([0, 24, 48]), `${48 + TREE_WIDTH_FLOOR_PX}px`);
  });

  it("is a full row wide even when nothing is indented", () => {
    assert.equal(treeMinWidth([0, 0]), TREE_WIDTH_FLOOR_PX);
    assert.equal(treeMinWidth([]), TREE_WIDTH_FLOOR_PX);
  });

  it("rounds up, so a sub-pixel indent never clips the last row", () => {
    assert.equal(treeMinWidth([23.4]), TREE_WIDTH_FLOOR_PX + 24);
  });

  it("floors at the same number app.js floors at", () => {
    const source = readFileSync(new URL("../../app.js", import.meta.url), "utf8");
    assert.ok(source.includes(`TREE_WIDTH_FLOOR_PX = ${TREE_WIDTH_FLOOR_PX}`));
  });
});


describe("revealing a deep-linked task", () => {
  it("names every collapsed ancestor between the root and the task", () => {
    const store = new FakeStore();
    writeCollapsed(store, 7, 10, true);
    writeCollapsed(store, 7, 12, true);
    const collapsed = (id: number) => readCollapsed(store, 7, id);

    assert.deepEqual(branchesToOpen(model(), 13, collapsed), [10, 12]);
  });

  it("leaves an already-open ancestor alone, and never names the root", () => {
    assert.deepEqual(branchesToOpen(model(), 13, open), []);
    assert.deepEqual(branchesToOpen(model(), 11, closedSet(10)), [10]);
  });

  it("says nothing for a task this tree does not hold", () => {
    assert.deepEqual(branchesToOpen(model(), 404, closedSet(10)), []);
  });

  it("does not ask to open the task itself, only the way down to it", () => {
    assert.deepEqual(branchesToOpen(model(), 12, closedSet(10, 12)), [10]);
  });
});

describe("seeding a tree's open state", () => {
  it("reads every task's saved state in one pass", () => {
    const store = new FakeStore();
    writeCollapsed(store, 7, 10, true);
    writeCollapsed(store, 7, 12, true);

    const seeded = seedCollapsed(model(), (id) => readCollapsed(store, 7, id));
    assert.deepEqual([...seeded].sort((a, b) => a - b), [10, 12]);
  });

  // Seeding happens again when a refetch brings new tasks; what the user has
  // collapsed since must not be undone by it.
  it("keeps what is already collapsed and only asks about the rest", () => {
    const asked: number[] = [];
    const seeded = seedCollapsed(
      model(),
      (id) => {
        asked.push(id);
        return id === 12;
      },
      new Set([10, 11]),
    );

    assert.deepEqual([...seeded].sort((a, b) => a - b), [10, 11, 12]);
    assert.deepEqual(asked.sort((a, b) => a - b), [12, 13, 20]);
  });

  it("hands back the same set when nothing changed", () => {
    const already = new Set([10]);
    assert.equal(seedCollapsed(model(), (id) => id === 10, already), already);
  });
});
