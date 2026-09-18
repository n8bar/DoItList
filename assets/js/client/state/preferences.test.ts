import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { initialSortState, withMode } from "../screens/initiatives_model.ts";
import {
  createPreferencesStore,
  initialRowPreferences,
  rowPreferencesFrom,
  setIndexSort,
  setRowPreferences,
  setTouchPreference,
} from "./preferences.ts";

describe("the touch layout preference (m04.02 item 7.8)", () => {
  it("starts off and flips in place, without touching the rest", () => {
    const store = createPreferencesStore();
    assert.equal(store.get().touch, false);
    const before = store.get();
    setTouchPreference(store, true);
    assert.equal(store.get().touch, true);
    assert.equal(store.get().rows, before.rows);
    setTouchPreference(store, true);
    assert.equal(store.get().touch, true);
  });
});

describe("the row preferences", () => {
  it("start with everything shown, as the server's defaults do", () => {
    assert.deepEqual(initialRowPreferences, {
      priority: true,
      assignee: true,
      progress: true,
      count: true,
    });
    assert.deepEqual(createPreferencesStore().get().rows, initialRowPreferences);
  });

  it("read the session payload's four flags", () => {
    const rows = rowPreferencesFrom({
      show_task_priority: false,
      show_task_assignee: true,
      show_task_progress: false,
      show_task_count: true,
    });

    assert.deepEqual(rows, { priority: false, assignee: true, progress: false, count: true });
  });

  it("falls back to shown for anything the payload did not carry", () => {
    assert.deepEqual(rowPreferencesFrom({ show_task_count: false }), {
      priority: true,
      assignee: true,
      progress: true,
      count: false,
    });
    assert.deepEqual(rowPreferencesFrom({ show_task_priority: "no" }), initialRowPreferences);
    assert.deepEqual(rowPreferencesFrom(null), initialRowPreferences);
    assert.deepEqual(rowPreferencesFrom(undefined), initialRowPreferences);
  });

  it("does not wake the store when the flags did not change", () => {
    const store = createPreferencesStore();
    let woken = 0;
    store.subscribe(() => (woken += 1));

    setRowPreferences(store, rowPreferencesFrom({}));
    assert.equal(woken, 0);

    setRowPreferences(store, rowPreferencesFrom({ show_task_assignee: false }));
    assert.equal(woken, 1);
    assert.equal(store.get().rows.assignee, false);
  });
});

describe("the index sort (item 7.3)", () => {
  it("starts on Recent and files what is set, without waking on the same value", () => {
    const store = createPreferencesStore();
    assert.deepEqual(store.get().indexSort, initialSortState);
    let woken = 0;
    store.subscribe(() => (woken += 1));

    setIndexSort(store, initialSortState);
    assert.equal(woken, 0);

    const name = withMode(initialSortState, "name");
    setIndexSort(store, name);
    assert.equal(woken, 1);
    assert.equal(store.get().indexSort, name);
  });
});
