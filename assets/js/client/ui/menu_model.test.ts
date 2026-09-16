import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { MenuItemModel } from "./menu_model.ts";
import { firstEnabled, menuItemDomId, nextFocusIndex } from "./menu_model.ts";

const items: readonly MenuItemModel[] = [
  { id: "expand-all", label: "Expand all" },
  { id: "collapse-all", label: "Collapse all" },
  { id: "collapse-subtree", label: "Collapse this subtree", disabled: true },
  { id: "remove", label: "Remove", danger: true },
];

describe("roving focus through a menu (guardrails §3.3)", () => {
  it("moves down and wraps to the top", () => {
    assert.equal(nextFocusIndex(items, 0, "ArrowDown"), 1);
    assert.equal(nextFocusIndex(items, 3, "ArrowDown"), 0);
  });

  it("moves up and wraps to the bottom", () => {
    assert.equal(nextFocusIndex(items, 1, "ArrowUp"), 0);
    assert.equal(nextFocusIndex(items, 0, "ArrowUp"), 3);
  });

  it("steps over an item that cannot be used", () => {
    assert.equal(nextFocusIndex(items, 1, "ArrowDown"), 3, "skipped the disabled item");
    assert.equal(nextFocusIndex(items, 3, "ArrowUp"), 1);
  });

  it("jumps to the ends", () => {
    assert.equal(nextFocusIndex(items, 2, "Home"), 0);
    assert.equal(nextFocusIndex(items, 0, "End"), 3);
  });

  it("does not jump onto a disabled item at an end", () => {
    const edges: readonly MenuItemModel[] = [
      { id: "a", label: "A", disabled: true },
      { id: "b", label: "B" },
      { id: "c", label: "C", disabled: true },
    ];

    assert.equal(nextFocusIndex(edges, 1, "Home"), 1);
    assert.equal(nextFocusIndex(edges, 1, "End"), 1);
  });

  it("leaves other keys to the browser", () => {
    assert.equal(nextFocusIndex(items, 0, "Tab"), null);
    assert.equal(nextFocusIndex(items, 0, "a"), null);
  });

  it("has somewhere to go even from nowhere", () => {
    assert.equal(nextFocusIndex(items, -1, "ArrowDown"), 0);
    assert.equal(nextFocusIndex(items, -1, "ArrowUp"), 3);
  });

  it("gives up gracefully when nothing can be used", () => {
    const none: readonly MenuItemModel[] = [{ id: "a", label: "A", disabled: true }];
    assert.equal(nextFocusIndex(none, 0, "ArrowDown"), null);
    assert.equal(firstEnabled([]), null);
  });
});

describe("menu item ids", () => {
  it("namespaces each item under its menu", () => {
    assert.equal(menuItemDomId("tree-tools", "expand-all"), "tree-tools-item-expand-all");
  });
});
