import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  MAX_ENTRIES,
  emptyNavigationMemory,
  focusTarget,
  recall,
  remember,
  restorationPlan,
} from "./navigation.ts";

const place = (scrollTop: number, focusElementId: string | null = null) => ({
  scrollTop,
  focusElementId,
});

describe("remember / recall", () => {
  it("records a place and reads it back", () => {
    const memory = remember(emptyNavigationMemory, "k1", place(340, "task-9"));
    assert.deepEqual(recall(memory, "k1"), {
      key: "k1",
      scrollTop: 340,
      focusElementId: "task-9",
    });
  });

  it("does not mutate the memory it was given", () => {
    const first = remember(emptyNavigationMemory, "k1", place(10));
    const second = remember(first, "k2", place(20));
    assert.equal(first.length, 1);
    assert.equal(second.length, 2);
  });

  it("overwrites a key and moves it to the most-recent end", () => {
    let memory = remember(emptyNavigationMemory, "k1", place(10));
    memory = remember(memory, "k2", place(20));
    memory = remember(memory, "k1", place(99, "heading"));

    assert.deepEqual(
      memory.map((entry) => entry.key),
      ["k2", "k1"],
    );
    assert.equal(recall(memory, "k1")?.scrollTop, 99);
  });

  it("normalises a fractional or negative scroll position", () => {
    const memory = remember(emptyNavigationMemory, "k1", place(12.6));
    assert.equal(recall(memory, "k1")?.scrollTop, 13);
    assert.equal(recall(remember(memory, "k2", place(-5)), "k2")?.scrollTop, 0);
  });

  it("keeps only the most recent entries", () => {
    let memory = emptyNavigationMemory;
    for (let i = 0; i < MAX_ENTRIES + 10; i += 1) {
      memory = remember(memory, `k${i}`, place(i));
    }
    assert.equal(memory.length, MAX_ENTRIES);
    assert.equal(recall(memory, "k0"), undefined);
    assert.equal(recall(memory, `k${MAX_ENTRIES + 9}`)?.scrollTop, MAX_ENTRIES + 9);
  });
});

describe("restorationPlan", () => {
  const memory = remember(emptyNavigationMemory, "k1", place(420, "task-9"));

  it("sends a new navigation to the top, focused on the heading", () => {
    for (const kind of ["initial", "push", "replace"] as const) {
      assert.deepEqual(
        restorationPlan(kind, "k1", memory),
        { scrollTop: 0, focusElementId: null },
        kind,
      );
    }
  });

  it("restores scroll and focus on back/forward", () => {
    assert.deepEqual(restorationPlan("pop", "k1", memory), {
      scrollTop: 420,
      focusElementId: "task-9",
    });
  });

  it("falls back to the top for an entry it never saw", () => {
    assert.deepEqual(restorationPlan("pop", "unknown", memory), {
      scrollTop: 0,
      focusElementId: null,
    });
  });
});

describe("focusTarget", () => {
  const always = () => true;
  const never = () => false;

  it("uses the remembered element when it is still on the page", () => {
    assert.deepEqual(focusTarget({ scrollTop: 0, focusElementId: "task-9" }, always), {
      kind: "element",
      id: "task-9",
    });
  });

  it("falls back to the heading when the remembered element is gone", () => {
    assert.deepEqual(focusTarget({ scrollTop: 0, focusElementId: "task-9" }, never), {
      kind: "heading",
    });
  });

  it("uses the heading when nothing was remembered", () => {
    assert.deepEqual(focusTarget({ scrollTop: 0, focusElementId: null }, always), {
      kind: "heading",
    });
  });
});
