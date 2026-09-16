import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { buildTree } from "./gen.ts";
import { INDEX_STYLES, label, relabel, validStyle } from "./labels.ts";
import { fromSnapshot } from "./model.ts";

describe("index styles", () => {
  it("accepts exactly the five fixed styles", () => {
    assert.deepEqual([...INDEX_STYLES].sort(), [
      "alphabetical",
      "none",
      "numerical",
      "outline",
      "roman",
    ]);
    for (const style of INDEX_STYLES) assert.ok(validStyle(style), style);
    assert.equal(validStyle("bogus"), false);
    assert.equal(validStyle("Outline"), false);
  });
});

describe("label (a port of DoIt.Tasks.Index.label/2)", () => {
  it("says nothing for the none style, at any depth", () => {
    assert.equal(label([0], "none"), "");
    assert.equal(label([0, 1, 2], "none"), "");
  });

  it("says nothing for no positions or an unknown style", () => {
    assert.equal(label([], "numerical"), "");
    assert.equal(label([0, 1], "bogus"), "");
  });

  it("numbers one 1-based segment per level", () => {
    assert.equal(label([0], "numerical"), "1");
    assert.equal(label([0, 0], "numerical"), "1.1");
    assert.equal(label([0, 1, 2], "numerical"), "1.2.3");
    assert.equal(label([2, 0, 9], "numerical"), "3.1.10");
  });

  it("uses uppercase roman at every level", () => {
    assert.equal(label([0], "roman"), "I");
    assert.equal(label([0, 1, 2], "roman"), "I.II.III");
    assert.equal(label([3], "roman"), "IV");
    assert.equal(label([8], "roman"), "IX");
  });

  it("uses uppercase letters at every level, wrapping past Z", () => {
    assert.equal(label([0], "alphabetical"), "A");
    assert.equal(label([0, 1, 2], "alphabetical"), "A.B.C");
    assert.equal(label([25], "alphabetical"), "Z");
    assert.equal(label([26], "alphabetical"), "AA");
    assert.equal(label([27], "alphabetical"), "AB");
  });

  it("alternates the outline cycle by depth, and repeats it", () => {
    assert.equal(label([0], "outline"), "I");
    assert.equal(label([0, 0], "outline"), "I.A");
    assert.equal(label([0, 0, 0], "outline"), "I.A.1");
    assert.equal(label([0, 0, 0, 0], "outline"), "I.A.1.a");
    assert.equal(label([0, 0, 0, 0, 0], "outline"), "I.A.1.a.i");
    assert.equal(label([0, 0, 0, 0, 0, 0], "outline"), "I.A.1.a.i.I");
  });

  it("tracks sibling positions, not just first slots", () => {
    assert.equal(label([2, 1, 3], "outline"), "III.B.4");
  });

  it("follows a node's position rather than its identity", () => {
    assert.equal(label([0, 1], "numerical"), "1.2");
    assert.equal(label([2, 0], "numerical"), "3.1");
  });
});

const sample = () =>
  fromSnapshot(
    buildTree([
      { id: 10, children: [{ id: 11 }, { id: 12, children: [{ id: 13 }] }] },
      { id: 20 },
    ]),
  );

describe("relabel", () => {
  it("relabels a run and its subtrees after the order changes", () => {
    const model = sample();
    const swapped = {
      ...model,
      childIds: { ...model.childIds, 10: [12, 11] },
    };

    const next = relabel(swapped, 10);

    assert.equal(next.tasks[12]?.index, "1.1");
    assert.equal(next.tasks[13]?.index, "1.1.1");
    assert.equal(next.tasks[11]?.index, "1.2");
  });

  it("leaves records outside the stale run with their identity intact", () => {
    const model = sample();
    const swapped = { ...model, childIds: { ...model.childIds, 10: [12, 11] } };

    const next = relabel(swapped, 10);

    assert.equal(next.tasks[20], model.tasks[20], "an untouched sibling was rebuilt");
    assert.equal(next.tasks[10], model.tasks[10], "the parent itself was rebuilt");
  });

  it("is the same object when nothing actually moved", () => {
    const model = sample();
    assert.equal(relabel(model, 10), model);
    assert.equal(relabel(model, model.rootId), model);
  });

  it("stamps depth from the parent down", () => {
    const model = relabel(sample(), 12);
    assert.equal(model.tasks[13]?.depth, 2);
  });

  it("does nothing for a parent that is not in the tree", () => {
    const model = sample();
    assert.equal(relabel(model, 999), model);
  });
});
