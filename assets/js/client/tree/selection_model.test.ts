import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { createStore } from "../state/store.ts";
import type { SelectionState } from "./selection_model.ts";
import {
  clickedSelection,
  forgetMissing,
  keptSelection,
  noSelection,
  rememberSelection,
  selectionOf,
  stillClosed,
} from "./selection_model.ts";

describe("what a row click selects", () => {
  it("selects the row", () => {
    assert.equal(clickedSelection(null, 12), 12);
    assert.equal(clickedSelection(7, 12), 12);
  });

  it("clears the selection when the row is the selected one, as the workspace's click does", () => {
    assert.equal(clickedSelection(12, 12), null);
  });
});

describe("the selection a row reads for itself", () => {
  it("reads the store's selected task and hears it change", () => {
    const store = createStore<{ selectedTaskId: number | null; other: number }>({ selectedTaskId: null, other: 0 });
    const selection = selectionOf(store);
    let heard = 0;
    const stop = selection.subscribe(() => {
      heard += 1;
    });
    assert.equal(selection.get(), null);
    store.set((state) => ({ ...state, selectedTaskId: 12 }));
    assert.equal(selection.get(), 12);
    assert.equal(heard, 1);
    stop();
    store.set((state) => ({ ...state, selectedTaskId: null }));
    assert.equal(heard, 1);
  });
});

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

describe("a remembered task that no longer exists", () => {
  const alive = (id: number) => id === 10 || id === 11;

  it("is forgotten, so Enter falls back to the first visible row", () => {
    const state = forgetMissing({ selectedId: null, lastSelectedId: 12 }, alive);
    assert.equal(state.lastSelectedId, null);
  });

  it("leaves a remembered task that is still there", () => {
    const state: SelectionState = { selectedId: null, lastSelectedId: 11 };
    assert.equal(forgetMissing(state, alive), state);
  });

  it("forgets a task selected in another Initiative", () => {
    const state = forgetMissing({ selectedId: 4321, lastSelectedId: 4321 }, alive);
    assert.deepEqual(state, { selectedId: 4321, lastSelectedId: null });
  });
});

describe("pruning while a reveal is still opening branches", () => {
  // The reveal asks for branches to open; the list of visible rows only catches
  // up on the next render. Pruning in between looks at a tree where the revealed
  // task is still buried and clears the very selection the link asked for.
  it("waits while any branch it asked for is still closed", () => {
    assert.deepEqual(stillClosed([10, 12], (id) => id === 12), [12]);
  });

  it("is done once they have all opened", () => {
    assert.deepEqual(stillClosed([10, 12], () => false), []);
  });

  it("has nothing to wait for when no branch had to open", () => {
    assert.deepEqual(stillClosed([], () => true), []);
  });
});
