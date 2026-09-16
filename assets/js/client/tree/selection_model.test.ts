import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { SelectionState } from "./selection_model.ts";
import { keptSelection, noSelection, rememberSelection } from "./selection_model.ts";

describe("what Enter reopens", () => {
  it("remembers the last task that was actually selected", () => {
    let state: SelectionState = noSelection;
    state = rememberSelection(state, 12);
    assert.deepEqual(state, { selectedId: 12, lastSelectedId: 12 });
  });

  it("keeps the last selection through a clear, which is the point of it", () => {
    const cleared = rememberSelection({ selectedId: 12, lastSelectedId: 12 }, null);
    assert.deepEqual(cleared, { selectedId: null, lastSelectedId: 12 });
  });

  it("does not churn when the same task is selected again", () => {
    const state = { selectedId: 12, lastSelectedId: 12 };
    assert.equal(rememberSelection(state, 12), state);
  });
});

describe("a selection that has gone off screen", () => {
  const visible = [10, 11];

  it("is dropped once the screen has settled", () => {
    assert.equal(keptSelection(13, visible, true), null);
    assert.equal(keptSelection(11, visible, true), 11);
  });

  // The deep link expands ancestors a moment after the first paint. Clearing an
  // "invisible" selection before that would undo the reveal.
  it("is left alone until then", () => {
    assert.equal(keptSelection(13, visible, false), 13);
  });

  it("leaves an empty selection empty", () => {
    assert.equal(keptSelection(null, visible, true), null);
  });
});
