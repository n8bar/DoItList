import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { collapsedOf, createCollapseStore, setCollapsedIn } from "./collapse_model.ts";

describe("the closed set as a store (7.9.1)", () => {
  it("answers per branch and tells subscribers only when the set changes", () => {
    const store = createCollapseStore();
    const reader = collapsedOf(store);
    let heard = 0;
    reader.subscribe(() => (heard += 1));

    assert.equal(reader.get(7), false);
    setCollapsedIn(store, 7, true);
    assert.equal(reader.get(7), true);
    assert.equal(heard, 1);

    // The same write again changes nothing and says nothing.
    const before = store.get();
    setCollapsedIn(store, 7, true);
    assert.equal(store.get(), before);
    assert.equal(heard, 1);

    setCollapsedIn(store, 7, false);
    assert.equal(reader.get(7), false);
    assert.equal(heard, 2);
  });

  it("starts from a seeded set without copying it", () => {
    const seed = new Set([1, 2]);
    const store = createCollapseStore(seed);
    assert.equal(store.get(), seed);
    assert.equal(collapsedOf(store).get(2), true);
  });
});
