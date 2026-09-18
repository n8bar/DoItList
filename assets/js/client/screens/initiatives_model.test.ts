import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ArchivedInitiative, InitiativeArchive, InitiativeSummary, TrashedInitiative } from "../api/types.ts";
import {
  accountSortRequest,
  adoptSortReply,
  applyOrder,
  archiveDrawerTitle,
  archiveHasRows,
  archiveStep,
  archivedRowActions,
  hasHidden,
  purgeConfirmText,
  removeRequest,
  stateRequest,
  trashedRowActions,
  trashedText,
  visibleArchived,
  withJoined,
  withoutJoined,
  createdInitiative,
  descriptionText,
  dropSide,
  droppedOrder,
  indexSortFrom,
  initialSortState,
  manualOrder,
  mergeSummaries,
  newInitiativeRequest,
  patchSummary,
  percentText,
  positionRequest,
  reversed,
  revertOrder,
  roleBadgeClass,
  sortInitiatives,
  storedOrder,
  subtitleText,
  summaryForCreated,
  updatedText,
  withMode,
  withReverse,
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

describe("the sort choice on the account (item 7.3)", () => {
  it("reads the session's mode and that mode's reverse", () => {
    assert.deepEqual(indexSortFrom({ index_sort: "updated", index_sort_reverse: true }), {
      mode: "updated",
      reverseByMode: { updated: true },
    });
    assert.deepEqual(indexSortFrom({ index_sort: null, index_sort_reverse: false }), {
      mode: "",
      reverseByMode: { "": false },
    });
  });

  it("falls back to Recent on nothing, garbage, or an unknown mode", () => {
    assert.deepEqual(indexSortFrom(undefined), initialSortState);
    assert.deepEqual(indexSortFrom(null), initialSortState);
    assert.equal(indexSortFrom({ index_sort: "colour", index_sort_reverse: "yes" }).mode, "");
    assert.equal(reversed(indexSortFrom({ index_sort: "name", index_sort_reverse: "yes" })), false);
  });

  it("sends the mode alone when this client has not seen its reverse", () => {
    const booted = indexSortFrom({ index_sort: null, index_sort_reverse: false });
    assert.deepEqual(accountSortRequest(withMode(booted, "name")), {
      operations: [{ op: "update", type: "account", data: { index_sort: "name" } }],
    });
  });

  it("sends both once the reverse for the mode is known, and null for Recent", () => {
    const state = withReverse(withMode(initialSortState, "name"), true);
    assert.deepEqual(accountSortRequest(state).operations[0]!.data, {
      index_sort: "name",
      index_sort_reverse: true,
    });
    const recent = withReverse(initialSortState, false);
    assert.deepEqual(accountSortRequest(withMode(withReverse(initialSortState, true), "")).operations[0]!.data, {
      index_sort: null,
      index_sort_reverse: true,
    });
    assert.deepEqual(accountSortRequest(recent).operations[0]!.data, { index_sort: null });
  });

  it("adopts the reply's reverse for a mode it did not know", () => {
    const state = withMode(initialSortState, "name");
    const reply = { results: [{ status: "ok", data: { type: "account", index_sort: "name", index_sort_reverse: true } }] };
    assert.deepEqual(adoptSortReply(state, reply), { mode: "name", reverseByMode: { name: true } });
    const off = { results: [{ status: "ok", data: { type: "account", index_sort: "name", index_sort_reverse: false } }] };
    assert.deepEqual(adoptSortReply(state, off), { mode: "name", reverseByMode: { name: false } });
  });

  it("leaves a flag the user set, a mode they moved off, or a bad reply alone", () => {
    // Ticked then cleared: the flag is known false, not merely absent.
    const set = withReverse(withReverse(withMode(initialSortState, "name"), true), false);
    const reply = { results: [{ status: "ok", data: { index_sort: "name", index_sort_reverse: true } }] };
    assert.equal(adoptSortReply(set, reply), set);
    const moved = withMode(initialSortState, "progress");
    assert.equal(adoptSortReply(moved, reply), moved);
    assert.equal(adoptSortReply(moved, null), moved);
    assert.equal(adoptSortReply(moved, { results: [] }), moved);
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

describe("dropSide", () => {
  it("is before above the midline and after below it", () => {
    assert.equal(dropSide(100, 40, 110), "before");
    assert.equal(dropSide(100, 40, 120), "before");
    assert.equal(dropSide(100, 40, 121), "after");
  });
});

describe("droppedOrder", () => {
  const shown = [1, 2, 3, 4];

  it("moves the row before or after the target", () => {
    assert.deepEqual(droppedOrder(shown, 4, 1, "before"), [4, 1, 2, 3]);
    assert.deepEqual(droppedOrder(shown, 1, 4, "after"), [2, 3, 4, 1]);
    assert.deepEqual(droppedOrder(shown, 1, 2, "after"), [2, 1, 3, 4]);
    assert.deepEqual(droppedOrder(shown, 4, 3, "before"), [1, 2, 4, 3]);
  });

  it("is null when nothing would move", () => {
    assert.equal(droppedOrder(shown, 2, 2, "after"), null);
    assert.equal(droppedOrder(shown, 2, 9, "after"), null);
    assert.equal(droppedOrder(shown, 9, 2, "after"), null);
    // Its own slot, approached from either neighbour.
    assert.equal(droppedOrder(shown, 2, 1, "after"), null);
    assert.equal(droppedOrder(shown, 2, 3, "before"), null);
  });

  it("does not touch the input", () => {
    const input = [1, 2, 3];
    droppedOrder(input, 3, 1, "before");
    assert.deepEqual(input, [1, 2, 3]);
  });
});

describe("storedOrder", () => {
  it("is the shown order, reversed only when Manual is reversed", () => {
    const manual = withMode(initialSortState, "manual");
    assert.deepEqual(storedOrder([3, 1, 2], manual), [3, 1, 2]);
    assert.deepEqual(storedOrder([3, 1, 2], withReverse(manual, true)), [2, 1, 3]);
  });

  it("ignores another mode's reverse", () => {
    const state = withReverse(withMode(initialSortState, "name"), true);
    assert.deepEqual(storedOrder([3, 1, 2], withMode(state, "manual")), [3, 1, 2]);
  });
});

describe("applyOrder / revertOrder", () => {
  const three = [row({ id: 1, sort_order: null }), row({ id: 2, sort_order: 0 }), row({ id: 3, sort_order: 1 })];

  it("numbers every listed row by its slot and keeps the rest", () => {
    const next = applyOrder(three, [3, 1]);
    assert.deepEqual(
      next.map((r) => [r.id, r.sort_order]),
      [
        [1, 1],
        [2, 0],
        [3, 0],
      ],
    );
    // Unchanged rows are the same objects, so nothing re-renders for them.
    assert.equal(next[1], three[1]);
  });

  it("revert puts the prior sort_order back, leaving rows it never saw alone", () => {
    const moved = applyOrder(three, [3, 1, 2]);
    const added = row({ id: 4, sort_order: 7 });
    const back = revertOrder([...moved, added], three);
    assert.deepEqual(
      back.map((r) => [r.id, r.sort_order]),
      [
        [1, null],
        [2, 0],
        [3, 1],
        [4, 7],
      ],
    );
  });

  it("a drop in manual sorts to where it was dropped", () => {
    const manual = withMode(initialSortState, "manual");
    const shown = sortInitiatives(three, manual).map((r) => r.id);
    assert.deepEqual(shown, [2, 3, 1]);
    const next = droppedOrder(shown, 1, 2, "before") as number[];
    const placed = applyOrder(three, storedOrder(next, manual));
    assert.deepEqual(
      sortInitiatives(placed, manual).map((r) => r.id),
      [1, 2, 3],
    );
  });
});

describe("positionRequest", () => {
  it("is one update initiative op with the slot", () => {
    assert.deepEqual(positionRequest(7, 2), {
      operations: [{ op: "update", type: "initiative", id: 7, data: { position: 2 } }],
    });
  });
});

// --- The Archived and Trash drawer (item 4.5) -------------------------------

function archived(
  overrides: Partial<ArchivedInitiative> & { id: number },
): ArchivedInitiative {
  return { ...row(overrides), hidden: false, ...overrides };
}

function trashed(overrides: Partial<TrashedInitiative> & { id: number }): TrashedInitiative {
  return { ...row(overrides), hidden: false, trashed_at: "2026-09-17T10:00:00Z", ...overrides };
}

const drawer: InitiativeArchive = {
  archived: [
    archived({ id: 10, archived: true }),
    archived({ id: 11, hidden: true }),
    archived({ id: 12, archived: true, hidden: true }),
  ],
  trashed: [trashed({ id: 20 })],
  retention_days: 30,
};

describe("the drawer's rows and title", () => {
  it("shows archived rows always and hidden-only rows under Show hidden", () => {
    assert.deepEqual(ids(visibleArchived(drawer.archived, false)), [10, 12]);
    assert.deepEqual(ids(visibleArchived(drawer.archived, true)), [10, 11, 12]);
    assert.equal(hasHidden(drawer.archived), true);
    assert.equal(hasHidden([archived({ id: 1, archived: true })]), false);
  });

  it("counts what is visible for Archived and everything for Trash", () => {
    assert.equal(archiveDrawerTitle(drawer, false), "Archived (2) · Trash (1)");
    assert.equal(archiveDrawerTitle(drawer, true), "Archived (3) · Trash (1)");
    assert.equal(archiveDrawerTitle({ ...drawer, trashed: [] }, false), "Archived (2)");
    assert.equal(archiveDrawerTitle({ ...drawer, archived: [] }, true), "Trash (1)");
  });

  it("is drawn only when a bucket has rows", () => {
    assert.equal(archiveHasRows(null), false);
    assert.equal(archiveHasRows({ archived: [], trashed: [], retention_days: 30 }), false);
    assert.equal(archiveHasRows(drawer), true);
  });
});

describe("which buttons a row offers", () => {
  it("Restore while archived, Unhide while hidden, both when both", () => {
    assert.deepEqual(archivedRowActions(drawer.archived[0] as ArchivedInitiative), ["restore"]);
    assert.deepEqual(archivedRowActions(drawer.archived[1] as ArchivedInitiative), ["unhide"]);
    assert.deepEqual(archivedRowActions(drawer.archived[2] as ArchivedInitiative), [
      "restore",
      "unhide",
    ]);
  });

  it("only the owner restores or deletes from Trash", () => {
    assert.deepEqual(trashedRowActions(trashed({ id: 1 })), ["restore", "delete"]);
    assert.deepEqual(trashedRowActions(trashed({ id: 1, role: "editor" })), []);
  });
});

describe("what a press does before the server answers", () => {
  it("Restore frees an archived-only row onto the index", () => {
    const step = archiveStep(drawer, "archived", 10, "restore");
    assert.ok(step);
    assert.deepEqual(step.request, stateRequest(10, "unarchived"));
    assert.deepEqual(ids(step.archive.archived), [11, 12]);
    assert.equal(step.joined?.id, 10);
    assert.equal(step.joined?.archived, false);
    assert.equal("hidden" in (step.joined as object), false);
  });

  it("Restore on a row that is also hidden keeps it in the drawer, hidden", () => {
    const step = archiveStep(drawer, "archived", 12, "restore");
    assert.ok(step);
    assert.equal(step.joined, null);
    const kept = step.archive.archived.find((r) => r.id === 12);
    assert.deepEqual([kept?.archived, kept?.hidden], [false, true]);
  });

  it("Unhide frees a hidden-only row and posts unhidden", () => {
    const step = archiveStep(drawer, "archived", 11, "unhide");
    assert.ok(step);
    assert.deepEqual(step.request, stateRequest(11, "unhidden"));
    assert.equal(step.joined?.id, 11);
    assert.deepEqual(ids(step.archive.archived), [10, 12]);
  });

  it("Restore from Trash posts restored and leaves trashed_at behind", () => {
    const step = archiveStep(drawer, "trashed", 20, "restore");
    assert.ok(step);
    assert.deepEqual(step.request, stateRequest(20, "restored"));
    assert.deepEqual(step.archive.trashed, []);
    assert.equal("trashed_at" in (step.joined as object), false);
    assert.equal(archiveStep(drawer, "trashed", 20, "unhide"), null);
    assert.equal(archiveStep(drawer, "archived", 99, "restore"), null);
  });

  it("Delete from Trash posts remove initiative and joins nothing (7.4)", () => {
    const step = archiveStep(drawer, "trashed", 20, "delete");
    assert.ok(step);
    assert.deepEqual(step.request, removeRequest(20));
    assert.equal(step.joined, null);
    assert.deepEqual(step.archive.trashed, []);
    assert.deepEqual(step.archive.archived, drawer.archived);
    assert.equal(archiveStep(drawer, "archived", 10, "delete"), null);
    assert.equal(archiveStep(drawer, "trashed", 99, "delete"), null);
  });

  it("asks with the workspace's words before a Delete", () => {
    assert.equal(purgeConfirmText("Q3 Launch"), 'Permanently delete "Q3 Launch"? This can\'t be undone.');
    assert.deepEqual(removeRequest(7), {
      operations: [{ op: "remove", type: "initiative", id: 7 }],
    });
  });

  it("joins the index at the top and leaves it again on a refusal", () => {
    const joined = row({ id: 10 });
    const list = withJoined(rows, joined);
    assert.deepEqual(ids(list), [10, 1, 2, 3]);
    assert.deepEqual(ids(withoutJoined(list, 10)), [1, 2, 3]);
  });

  it("posts one update initiative op with the state", () => {
    assert.deepEqual(stateRequest(7, "restored"), {
      operations: [{ op: "update", type: "initiative", id: 7, data: { state: "restored" } }],
    });
  });

  it("dates the Trash row like the template", () => {
    const local = new Date(2026, 8, 17, 12).toISOString();
    assert.equal(trashedText(local), "trashed Sep 17");
    assert.equal(trashedText("nope"), "");
  });
});

describe("live list changes (item 4.6)", () => {
  const row = (id: number, patch: Partial<InitiativeSummary> = {}): InitiativeSummary => ({
    id,
    name: `Row ${id}`,
    subtitle: "",
    description: null,
    role: "owner",
    progress: 10,
    unit_count: 2,
    root_task_id: id * 10,
    version: 1,
    sort_order: null,
    archived: false,
    created_at: "2026-09-01T00:00:00Z",
    updated_at: "2026-09-01T00:00:00Z",
    ...patch,
  });

  it("mergeSummaries keeps an unchanged row's identity and hands back the same list", () => {
    const current = [row(1), row(2)];
    const merged = mergeSummaries(current, [row(1), row(2)]);
    assert.equal(merged, current);
  });

  it("mergeSummaries updates changed rows, adds new ones and drops missing ones", () => {
    const one = row(1);
    const current = [one, row(2), row(3)];
    const merged = mergeSummaries(current, [row(4), row(2, { progress: 60 }), one]);
    assert.deepEqual(
      merged.map((r) => r.id),
      [4, 2, 1],
    );
    assert.equal(merged[2], one, "an unchanged row keeps its object");
    assert.equal(merged[1]?.progress, 60);
    assert.notEqual(merged, current);
  });

  it("mergeSummaries follows the read's order even when the rows are the same", () => {
    const current = [row(1), row(2)];
    const merged = mergeSummaries(current, [row(2), row(1)]);
    assert.deepEqual(
      merged.map((r) => r.id),
      [2, 1],
    );
  });

  it("patchSummary replaces one row in place and never adds one", () => {
    const current = [row(1), row(2)];
    const patched = patchSummary(current, row(2, { progress: 90, updated_at: "2026-09-17T00:00:00Z" }));
    assert.deepEqual(
      patched.map((r) => [r.id, r.progress]),
      [
        [1, 10],
        [2, 90],
      ],
    );
    assert.equal(patched[0], current[0]);
    assert.equal(patchSummary(current, row(2)), current, "no change, same list");
    assert.equal(patchSummary(current, row(9)), current, "a stranger is not added");
  });
});
