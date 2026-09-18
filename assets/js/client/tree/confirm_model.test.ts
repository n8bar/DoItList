import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { KeyValueStore } from "../storage/last_user.ts";
import {
  CASCADE_SORT_THRESHOLD,
  confirmFor,
  descendantBranchCount,
  dialogIdFor,
  ensureSkipVersion,
  skipKey,
  suppress,
  suppressed,
} from "./confirm_model.ts";
import type { TaskSpec } from "./gen.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";

const modelOf = (specs: TaskSpec[]) => fromSnapshot(buildTree(specs, { id: 5, rootTaskId: 1 }));

// 10 Cabinets [11 Doors, 12 Handles (done)], 20 Paint (done) [21 Primer (done)], 30 Trim
const base = () =>
  modelOf([
    { id: 10, title: "Cabinets", children: [{ id: 11, title: "Doors" }, { id: 12, title: "Handles", status: "done" }] },
    { id: 20, title: "Paint", status: "done", children: [{ id: 21, title: "Primer", status: "done" }] },
    { id: 30, title: "Trim" },
  ]);

describe("confirmFor: cascade-complete", () => {
  it("asks before completing or reopening a branch, with the branch's title", () => {
    const complete = confirmFor(base(), { kind: "cascadeComplete", id: 10, done: true });
    assert.equal(complete?.class, "cascade-complete");
    assert.equal(complete?.title, "Complete this branch?");
    assert.equal(complete?.body, 'Mark "Cabinets" and all its subtasks complete?');
    assert.equal(complete?.checkboxLabel, "Don't show this again for branch completion changes");

    const reopen = confirmFor(base(), { kind: "cascadeComplete", id: 20, done: false });
    assert.equal(reopen?.title, "Reopen this branch?");
    assert.equal(reopen?.body, 'Reopen "Paint" and all its subtasks?');
  });

  it("never asks on a leaf, whichever intent carried the toggle", () => {
    assert.equal(confirmFor(base(), { kind: "toggleComplete", id: 11, done: true }), null);
    assert.equal(confirmFor(base(), { kind: "cascadeComplete", id: 30, done: true }), null);
    assert.equal(confirmFor(base(), { kind: "toggleComplete", id: 99, done: true }), null);
  });

  it("asks on a branch even through the leaf intent — the branch is what matters", () => {
    assert.equal(confirmFor(base(), { kind: "toggleComplete", id: 10, done: true })?.class, "cascade-complete");
  });
});

describe("confirmFor: completion-flip", () => {
  it("a move that completes one chain and reopens another says both", () => {
    // Doors leaves Cabinets (Handles alone → complete) for Paint (open work → reopen).
    const confirm = confirmFor(base(), { kind: "move", id: 11, parentId: 20, position: null, reorder: false });
    assert.equal(confirm?.class, "completion-flip");
    assert.equal(confirm?.title, "Confirm completion change");
    assert.equal(confirm?.body, "This move will mark some tasks complete and others incomplete.");
    assert.deepEqual([...(confirm?.titles ?? [])].sort(), ["Cabinets", "Paint"]);
    assert.equal(confirm?.checkboxLabel, "Don't show this again for completion changes");
  });

  it("a move that only reopens, and one that only completes, each say so", () => {
    // Trim (open) under Paint (done): Paint reopens.
    const reopens = confirmFor(base(), { kind: "move", id: 30, parentId: 20, position: null, reorder: false });
    assert.equal(reopens?.body, "This move will mark previously completed task(s) as incomplete.");
    assert.deepEqual(reopens?.titles, ["Paint"]);

    // Doors (open) out to the top: Cabinets is left all done.
    const completes = confirmFor(base(), { kind: "move", id: 11, parentId: 1, position: null, reorder: false });
    assert.equal(completes?.body, "This move will mark previously incomplete task(s) as complete.");
    assert.deepEqual(completes?.titles, ["Cabinets"]);
  });

  it("a keyboard indent or outdent asks the same question as a drag", () => {
    // Outdent Doors: same as the move to the top.
    assert.equal(
      confirmFor(base(), { kind: "outdent", id: 11 })?.body,
      "This move will mark previously incomplete task(s) as complete.",
    );
    // Indent Trim under Paint (its previous sibling, done): Paint reopens.
    assert.deepEqual(confirmFor(base(), { kind: "indent", id: 30 })?.titles, ["Paint"]);
  });

  it("a move that flips nothing, or has nowhere to go, does not ask", () => {
    assert.equal(confirmFor(base(), { kind: "reorder", id: 11, dir: "down" }), null);
    assert.equal(confirmFor(base(), { kind: "reorder", id: 10, dir: "up" }), null);
    assert.equal(confirmFor(base(), { kind: "move", id: 30, parentId: 10, position: null, reorder: false }), null);
    assert.equal(confirmFor(base(), { kind: "indent", id: 11 }), null);
  });

  it("an add under a done parent reopens it — and every done ancestor above", () => {
    const confirm = confirmFor(base(), { kind: "add", request: { parentId: 21, position: 0, title: "Coat" } });
    assert.equal(confirm?.class, "completion-flip");
    assert.equal(confirm?.body, "This new task will mark previously completed task(s) as incomplete.");
    assert.deepEqual(confirm?.titles, ["Primer", "Paint"]);
  });

  it("an add under open work, or at the top level, does not ask", () => {
    assert.equal(confirmFor(base(), { kind: "add", request: { parentId: 10, position: 0, title: "Shelves" } }), null);
    assert.equal(confirmFor(base(), { kind: "add", request: { parentId: 1, position: 0, title: "Floor" } }), null);
  });
});

describe("confirmFor: cascade-sort", () => {
  // `id` with `branches` descendant branches, each holding one leaf.
  const wide = (branches: number) =>
    modelOf([
      {
        id: 10,
        title: "Wide",
        children: Array.from({ length: branches }, (_, i) => ({
          id: 100 + i,
          children: [{ id: 1000 + i }],
        })),
      },
    ]);

  it("counts descendants that have children, not the branch itself or its leaves", () => {
    assert.equal(descendantBranchCount(wide(3), 10), 3);
    assert.equal(descendantBranchCount(base(), 10), 0);
    assert.equal(descendantBranchCount(base(), 1), 2);
  });

  it("asks only above the threshold, naming how many tasks it touches", () => {
    assert.equal(confirmFor(wide(CASCADE_SORT_THRESHOLD), { kind: "cascadeSort", id: 10 }), null);
    const confirm = confirmFor(wide(CASCADE_SORT_THRESHOLD + 1), { kind: "cascadeSort", id: 10 });
    assert.equal(confirm?.class, "cascade-sort");
    assert.equal(confirm?.title, "Large branch reorg");
    assert.match(confirm?.body ?? "", /^This is a large branch reorg affecting 22 task\(s\)\. Every descendant branch switches to Inherit/);
    assert.equal(confirm?.checkboxLabel, "Don't show this again for large branch reorgs");
  });

  it("the Initiative's own root counts the whole tree", () => {
    assert.equal(confirmFor(wide(11), { kind: "cascadeSort", id: 1 })?.class, "cascade-sort");
    assert.equal(confirmFor(base(), { kind: "cascadeSort", id: 1 }), null);
  });
});

describe("other writes", () => {
  it("edits, steps, sort changes, and deletes never open one of these", () => {
    assert.equal(confirmFor(base(), { kind: "edit", id: 11, fields: { title: "x" } }), null);
    assert.equal(confirmFor(base(), { kind: "step", id: 11, field: "priority", back: false }), null);
    assert.equal(confirmFor(base(), { kind: "setSort", id: 10, mode: "alphabetical", reverse: false }), null);
    assert.equal(confirmFor(base(), { kind: "delete", id: 10 }), null);
  });
});

// --- suppression --------------------------------------------------------------

const memoryStore = (seed: Record<string, string> = {}): KeyValueStore & { data: Map<string, string> } => {
  const data = new Map(Object.entries(seed));
  return {
    data,
    getItem: (key) => data.get(key) ?? null,
    setItem: (key, value) => void data.set(key, value),
    removeItem: (key) => void data.delete(key),
  };
};

describe("don't show this again", () => {
  it("reads and writes the LiveView's per-class key", () => {
    const store = memoryStore();
    assert.equal(suppressed(store, "cascade-complete"), false);
    suppress(store, "cascade-complete");
    assert.equal(store.getItem("doit:confirm-skip:cascade-complete"), "1");
    assert.equal(suppressed(store, "cascade-complete"), true);
    assert.equal(suppressed(store, "cascade-sort"), false);
    assert.equal(skipKey("completion-flip"), "doit:confirm-skip:completion-flip");
  });

  it("a stale or missing version stamp drops the keys and re-stamps; a current one is left alone", () => {
    const stale = memoryStore({ "doit:confirm-skip:cascade-sort": "1", "doit:confirm-skip:_v": "0" });
    ensureSkipVersion(stale);
    assert.equal(suppressed(stale, "cascade-sort"), false);
    assert.equal(stale.getItem("doit:confirm-skip:_v"), "1");

    const current = memoryStore({ "doit:confirm-skip:cascade-sort": "1", "doit:confirm-skip:_v": "1" });
    ensureSkipVersion(current);
    assert.equal(suppressed(current, "cascade-sort"), true);
  });

  it("no storage means every confirm asks", () => {
    assert.equal(suppressed(null, "completion-flip"), false);
    suppress(null, "completion-flip");
    ensureSkipVersion(null);
  });

  it("each class renders in the dialog the LiveView gave it", () => {
    assert.equal(dialogIdFor("cascade-complete"), "cascade-confirm");
    assert.equal(dialogIdFor("completion-flip"), "move-flip-confirm");
    assert.equal(dialogIdFor("cascade-sort"), "cascade-sort-confirm");
  });
});
