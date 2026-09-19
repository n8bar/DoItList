import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createStore } from "../state/store.ts";
import type { TaskSpec } from "./gen.ts";
import { buildTree } from "./gen.ts";
import type { TreeModel } from "./model.ts";
import { fromSnapshot } from "./model.ts";
import { addTask, moveTask } from "./ops.ts";
import { predictLineage } from "./progress.ts";
import type { RowMarks } from "./task_store.ts";
import { NO_MARKS, createTaskReader } from "./task_store.ts";

// The tree under test:
//   10 Alpha
//     11 Beta
//       12 Gamma   (leaf)
//       13 Delta   (leaf)
//     14 Epsilon   (leaf)
//   20 Zeta
//     21 Eta       (leaf, "see %<12>")
const specs: TaskSpec[] = [
  {
    id: 10,
    title: "Alpha",
    children: [
      { id: 11, title: "Beta", children: [{ id: 12, title: "Gamma", manual_progress: 20 }, { id: 13, title: "Delta", manual_progress: 40 }] },
      { id: 14, title: "Epsilon", manual_progress: 60 },
    ],
  },
  { id: 20, title: "Zeta", children: [{ id: 21, title: "Eta", description: "see %<12>", manual_progress: 0 }] },
];
const ALL = [10, 11, 12, 13, 14, 20, 21];

const modelOf = (): TreeModel => fromSnapshot(buildTree(specs));

/**
 * What `useSyncExternalStore` does, without React: on every notify, read the
 * snapshot again and count a render only when its identity changed. One probe
 * per row and per children list, so a delta's cost is read off the counts.
 */
function probe<V>(subscribe: (l: () => void) => () => void, read: () => V) {
  let last = read();
  let renders = 0;
  subscribe(() => {
    const next = read();
    if (!Object.is(next, last)) {
      renders += 1;
      last = next;
    }
  });
  return {
    get renders() {
      return renders;
    },
    get value() {
      return last;
    },
  };
}

function harness(marks: RowMarks = NO_MARKS) {
  const model = createStore<TreeModel | undefined>(modelOf());
  const marksStore = createStore(marks);
  const reader = createTaskReader(model, marksStore);
  const rows = new Map(ALL.map((id) => [id, probe(reader.subscribe, () => reader.row(id))]));
  const lists = new Map([1, ...ALL].map((id) => [id, probe(reader.subscribe, () => reader.children(id))]));
  const rendered = () => ALL.filter((id) => (rows.get(id)?.renders ?? 0) > 0);
  const listsRendered = () => [1, ...ALL].filter((id) => (lists.get(id)?.renders ?? 0) > 0);
  return { model, marksStore, reader, rows, lists, rendered, listsRendered };
}

describe("task reader (item 7.18)", () => {
  it("a row's view is the same object back until something it paints changes", () => {
    const { reader, model } = harness();
    const before = reader.row(12);
    assert.ok(before !== null);
    assert.equal(reader.row(12), before);
    // A refetch rebuilds every record; unchanged rows must still read as unchanged.
    model.set(modelOf());
    assert.equal(reader.row(12), before);
    assert.equal(reader.children(11), reader.children(11));
  });

  it("a single-leaf delta re-renders that row and its ancestors only", () => {
    const { model, rendered, listsRendered, rows } = harness();
    const current = model.get() as TreeModel;
    const gamma = current.tasks[12];
    assert.ok(gamma !== undefined);
    // Gamma done: its own value moves, and Beta's and Alpha's roll-ups with it.
    const touched: TreeModel = { ...current, tasks: { ...current.tasks, 12: { ...gamma, status: "done" } } };
    model.set(predictLineage(touched, 12).model);

    assert.deepEqual(rendered(), [10, 11, 12]);
    assert.deepEqual(listsRendered(), []);
    assert.equal(rows.get(12)?.value?.progress, 100);
    assert.equal(rows.get(12)?.renders, 1);
  });

  it("a relabel re-renders the label and the rows whose references read it, not the row itself", () => {
    const { model, reader, rendered } = harness();
    const current = model.get() as TreeModel;
    const gamma = current.tasks[12];
    assert.ok(gamma !== undefined);
    const label = probe(reader.subscribe, () => reader.label(12));
    model.set({ ...current, tasks: { ...current.tasks, 12: { ...gamma, index: "9.9.9" } } });
    // Eta says "see %<12>", and paints Gamma's label; Gamma's own label reads for itself (7.21).
    assert.deepEqual(rendered(), [21]);
    assert.equal(label.renders, 1);
    assert.equal(label.value, "9.9.9");
    const eta = reader.row(21);
    assert.deepEqual(eta?.description?.map((part) => (part.kind === "link" ? part.label : part.kind)), ["text", "9.9.9"]);
  });

  it("a reorder re-renders the one children list, and no row", () => {
    const { model, rendered, listsRendered, reader } = harness();
    const current = model.get() as TreeModel;
    model.set({ ...current, childIds: { ...current.childIds, 11: [13, 12] } });
    assert.deepEqual(listsRendered(), [11]);
    assert.deepEqual(rendered(), []);
    assert.deepEqual(reader.children(11).ids, [13, 12]);
  });

  it("a pending mark re-renders the marked row only, and the key follows the stand-in", () => {
    const { marksStore, rendered, reader, rows } = harness();
    marksStore.set({
      ...NO_MARKS,
      savingIds: new Set([13]),
      recomputingIds: new Set([11]),
      rowKeys: new Map([[13, -7]]),
    });
    assert.deepEqual(rendered(), [11, 13]);
    assert.equal(rows.get(13)?.value?.saving, true);
    assert.equal(rows.get(11)?.value?.recomputing, true);
    assert.equal(reader.keyOf(13), -7);
    assert.equal(reader.keyOf(12), 12);
  });

  it("an optimistic insert re-renders the host list and the roll-up chain, then keeps its key when the server id lands", () => {
    const { model, marksStore, reader, rendered, listsRendered, lists } = harness();
    const current = model.get() as TreeModel;
    // The stand-in first under Beta, as Enter on the N form places it.
    const begun = addTask(current, { tempId: -1, parentId: 11, position: 0, title: "Kilo" });
    assert.ok("model" in begun);
    marksStore.set({ ...NO_MARKS, savingIds: new Set([-1]) });
    model.set(begun.model);

    assert.deepEqual(listsRendered(), [11]);
    assert.deepEqual(reader.children(11).ids, [-1, 12, 13]);
    // Beta's and Alpha's roll-ups moved and Eta paints Gamma's label; the two
    // rows behind the new one only took new labels, which are not the row's (7.21).
    assert.deepEqual(rendered(), [10, 11, 21]);
    const standIn = reader.row(-1);
    assert.deepEqual(standIn?.title, [{ kind: "text", text: "Kilo" }]);
    assert.equal(standIn?.saving, true);
    assert.equal(reader.keyOf(-1), -1);

    // The reply: 99 takes the stand-in's place and its key.
    const landed = addTask(current, { tempId: 99, parentId: 11, position: 0, title: "Kilo" });
    assert.ok("model" in landed);
    marksStore.set({ ...NO_MARKS, rowKeys: new Map([[99, -1]]) });
    model.set(landed.model);

    assert.deepEqual(reader.children(11).ids, [99, 12, 13]);
    assert.equal(lists.get(11)?.renders, 2);
    assert.equal(reader.keyOf(99), -1);
    assert.equal(reader.row(-1), null);
    assert.equal(reader.row(99)?.saving, false);
  });

  it("a move to the root's start renumbers every label and re-renders the moved chain only", () => {
    // Ten rows: the seven, plus three more leaves under Zeta so the tree is wide enough to count.
    const wide: TaskSpec[] = [
      ...specs.slice(0, 1),
      { id: 20, title: "Zeta", children: [
        { id: 21, title: "Eta", description: "see %<12>", manual_progress: 0 },
        { id: 22, title: "Theta", manual_progress: 10 },
        { id: 23, title: "Iota", manual_progress: 20 },
        { id: 24, title: "Kappa", manual_progress: 30 },
      ] },
    ];
    const all = [10, 11, 12, 13, 14, 20, 21, 22, 23, 24];
    const model = createStore<TreeModel | undefined>(fromSnapshot(buildTree(wide)));
    const reader = createTaskReader(model, createStore(NO_MARKS));
    const rows = new Map(all.map((id) => [id, probe(reader.subscribe, () => reader.row(id))]));
    const labels = new Map(all.map((id) => [id, probe(reader.subscribe, () => reader.label(id))]));
    const current = model.get() as TreeModel;
    assert.equal(reader.label(12), "1.1.1");

    // Kappa, from the end of Zeta to the top of the tree.
    const moved = moveTask(current, { id: 24, parentId: current.rootId, position: 0 });
    assert.ok("model" in moved);
    model.set(moved.model);

    const rowsRendered = all.filter((id) => (rows.get(id)?.renders ?? 0) > 0);
    const labelsRendered = all.filter((id) => (labels.get(id)?.renders ?? 0) > 0);
    // The moved row (new parent), Zeta (its roll-up and unit count moved), and
    // Eta, whose description paints Gamma's label — no other row.
    assert.deepEqual(rowsRendered, [20, 21, 24]);
    // Every label but Kappa's own children (it has none): all ten renumbered.
    assert.deepEqual(labelsRendered, all);
    assert.equal(reader.label(24), "1");
    assert.equal(reader.label(12), "2.1.1");
    assert.equal(rows.get(12)?.renders, 0);
    assert.equal(rows.get(10)?.renders, 0);
  });

  it("a branch's view carries its unit counts and a leaf's carries none", () => {
    const { reader } = harness();
    assert.deepEqual(reader.row(10)?.units, { total: 3, done: 0 });
    assert.equal(reader.row(12)?.units, null);
    assert.equal(reader.row(11)?.branch, true);
    assert.equal(reader.children(1).ids.length, 2);
    assert.equal(reader.children(1).sortMode, "manual");
  });

  it("a gone task reads as null, and a gone model as empty", () => {
    const { reader, model } = harness();
    assert.equal(reader.row(99), null);
    const last = reader.model();
    model.set(undefined);
    assert.equal(reader.row(12), null);
    assert.deepEqual(reader.children(1).ids, []);
    // The last model stays readable for the render that takes the tree down.
    assert.equal(reader.model(), last);
    assert.throws(() => createTaskReader(createStore<TreeModel | undefined>(undefined)).model());
  });
});
