import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { InitiativeSummary } from "../api/types.ts";
import type { KeyValueStore } from "../storage/last_user.ts";
import {
  SORT_STORAGE_KEY,
  createdInitiative,
  descriptionText,
  initialSortState,
  manualOrder,
  newInitiativeRequest,
  percentText,
  readSortState,
  reversed,
  roleBadgeClass,
  sortInitiatives,
  subtitleText,
  summaryForCreated,
  updatedText,
  withMode,
  withReverse,
  writeSortState,
} from "./initiatives_model.ts";

function row(overrides: Partial<InitiativeSummary> & { id: number }): InitiativeSummary {
  return {
    name: `Initiative ${overrides.id}`,
    subtitle: "",
    description: null,
    role: "owner",
    progress: 0,
    unit_count: 0,
    root_task_id: overrides.id * 10,
    version: 1,
    sort_order: null,
    archived: false,
    created_at: "2026-01-01T00:00:00Z",
    updated_at: "2026-01-01T00:00:00Z",
    ...overrides,
  };
}

// Server order: owners first, then most recently updated.
const rows: InitiativeSummary[] = [
  row({ id: 1, name: "beta", progress: 40, created_at: "2026-03-01T00:00:00Z", updated_at: "2026-09-10T00:00:00Z", sort_order: 2 }),
  row({ id: 2, name: "Alpha", progress: 90, created_at: "2026-01-01T00:00:00Z", updated_at: "2026-09-01T00:00:00Z", sort_order: null }),
  row({ id: 3, name: "gamma", progress: 10, created_at: "2026-02-01T00:00:00Z", updated_at: "2026-08-01T00:00:00Z", sort_order: 1, role: "viewer" }),
];

const ids = (list: readonly InitiativeSummary[]) => list.map((item) => item.id);

describe("sorting the index (item 4.2)", () => {
  it("Recent keeps the server's order, and Reverse flips it", () => {
    assert.deepEqual(ids(sortInitiatives(rows, initialSortState)), [1, 2, 3]);
    const flipped = withReverse(initialSortState, true);
    assert.deepEqual(ids(sortInitiatives(rows, flipped)), [3, 2, 1]);
  });

  it("Name ignores case", () => {
    const state = withMode(initialSortState, "name");
    assert.deepEqual(ids(sortInitiatives(rows, state)), [2, 1, 3]);
    assert.deepEqual(ids(sortInitiatives(rows, withReverse(state, true))), [3, 1, 2]);
  });

  it("Progress is least complete first", () => {
    const state = withMode(initialSortState, "progress");
    assert.deepEqual(ids(sortInitiatives(rows, state)), [3, 1, 2]);
    assert.deepEqual(ids(sortInitiatives(rows, withReverse(state, true))), [2, 1, 3]);
  });

  it("Created and Updated are oldest first", () => {
    assert.deepEqual(ids(sortInitiatives(rows, withMode(initialSortState, "created"))), [2, 3, 1]);
    assert.deepEqual(ids(sortInitiatives(rows, withMode(initialSortState, "updated"))), [3, 2, 1]);
  });

  it("Manual follows the saved order, with never-dragged rows last in server order", () => {
    assert.deepEqual(manualOrder(rows), [3, 1]);
    const state = withMode(initialSortState, "manual");
    assert.deepEqual(ids(sortInitiatives(rows, state)), [3, 1, 2]);
    assert.deepEqual(ids(sortInitiatives(rows, withReverse(state, true))), [2, 1, 3]);
  });

  it("does not reorder the list it was given", () => {
    const before = ids(rows);
    sortInitiatives(rows, withReverse(withMode(initialSortState, "name"), true));
    assert.deepEqual(ids(rows), before);
  });

  it("remembers Reverse per mode, as the account preference does", () => {
    let state = withReverse(withMode(initialSortState, "name"), true);
    assert.equal(reversed(state), true);
    state = withMode(state, "progress");
    assert.equal(reversed(state), false);
    state = withMode(state, "name");
    assert.equal(reversed(state), true);
  });
});

describe("the card's words (item 4.3)", () => {
  it("shows the percent, reading nothing as zero", () => {
    assert.equal(percentText(42), "42%");
    assert.equal(percentText(null), "0%");
    assert.equal(percentText(undefined), "0%");
  });

  it("dates the update like the template, in local time", () => {
    // Midday UTC: the same calendar day in every timezone a browser can be in.
    const text = updatedText("2026-09-17T12:00:00Z");
    const local = new Date("2026-09-17T12:00:00Z");
    assert.equal(text, `Updated Sep ${local.getDate()}, ${local.getFullYear()}`);
    assert.equal(updatedText("not a date"), "");
  });

  it("hides a blank subtitle and a blank description", () => {
    assert.equal(subtitleText({ subtitle: " " }), null);
    assert.equal(subtitleText({ subtitle: " ship it " }), "ship it");
    assert.equal(descriptionText({ description: null }), null);
    assert.equal(descriptionText({ description: "  " }), null);
    assert.equal(descriptionText({ description: "why" }), "why");
  });

  it("colours the role badge as role_badge_class/1 does", () => {
    assert.match(roleBadgeClass("owner"), /emerald/);
    assert.match(roleBadgeClass("editor"), /blue/);
    assert.match(roleBadgeClass("viewer"), /zinc/);
  });
});

function fakeStore(initial: Record<string, string> = {}): KeyValueStore & { data: Record<string, string> } {
  const data = { ...initial };
  return {
    data,
    getItem: (key) => (key in data ? data[key]! : null),
    setItem: (key, value) => {
      data[key] = value;
    },
    removeItem: (key) => {
      delete data[key];
    },
  };
}

describe("remembering the sort choice", () => {
  it("round-trips through the store", () => {
    const store = fakeStore();
    const state = withReverse(withMode(initialSortState, "updated"), true);
    writeSortState(store, state);
    assert.deepEqual(readSortState(store), { mode: "updated", reverseByMode: { updated: true } });
  });

  it("falls back to Recent on nothing, garbage, or an unknown mode", () => {
    assert.deepEqual(readSortState(null), initialSortState);
    assert.deepEqual(readSortState(fakeStore()), initialSortState);
    assert.deepEqual(readSortState(fakeStore({ [SORT_STORAGE_KEY]: "{" })), initialSortState);
    assert.deepEqual(
      readSortState(fakeStore({ [SORT_STORAGE_KEY]: JSON.stringify({ mode: "colour", reverseByMode: { colour: true, name: "yes" } }) })),
      initialSortState,
    );
  });

  it("survives a store that throws", () => {
    const broken: KeyValueStore = {
      getItem: () => {
        throw new Error("blocked");
      },
      setItem: () => {
        throw new Error("blocked");
      },
      removeItem: () => {},
    };
    assert.deepEqual(readSortState(broken), initialSortState);
    assert.doesNotThrow(() => writeSortState(broken, initialSortState));
  });
});

describe("New Initiative (item 4.1)", () => {
  it("sends one add initiative op, leaving out an empty description", () => {
    assert.deepEqual(newInitiativeRequest({ name: " Q4 ", description: "" }), {
      operations: [{ op: "add", type: "initiative", data: { name: "Q4" } }],
    });
    assert.deepEqual(newInitiativeRequest({ name: "Q4", description: " why " }).operations[0]!.data, {
      name: "Q4",
      description: "why",
    });
  });

  it("reads the created row out of the batch reply", () => {
    const created = createdInitiative({
      results: [{ lid: null, id: 7, type: "initiative", data: { id: 7, type: "initiative", name: "Q4", root_task_id: 70, version: 1 } }],
    });
    assert.deepEqual(created, { id: 7, type: "initiative", name: "Q4", root_task_id: 70, version: 1 });
    assert.equal(createdInitiative({ results: [] }), null);
    assert.equal(createdInitiative({ results: [{ id: 1, type: "task" }] }), null);
    assert.equal(createdInitiative("nope"), null);
  });

  it("builds the owner's zero-progress index row for it", () => {
    const summary = summaryForCreated(
      { id: 7, type: "initiative", name: "Q4", root_task_id: 70, version: 1 },
      { name: "Q4", description: "why" },
      "2026-09-17T12:00:00Z",
    );
    assert.equal(summary.id, 7);
    assert.equal(summary.role, "owner");
    assert.equal(summary.progress, 0);
    assert.equal(summary.description, "why");
    assert.equal(summary.updated_at, "2026-09-17T12:00:00Z");
  });
});
