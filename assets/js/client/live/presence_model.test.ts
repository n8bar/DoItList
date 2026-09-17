import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  applyDiff,
  applyState,
  emptyPresence,
  onlineIds,
  parseMeta,
  selectionsOf,
} from "./presence_model.ts";
import type { PresenceMeta, PresenceState } from "./presence_model.ts";

/** A meta the way `DoItWeb.Presence.selection_meta/2` builds one, plus a ref. */
const meta = (user_id: number, task_id: number | null, ref: string): PresenceMeta => ({
  user_id,
  task_id,
  name: `User ${user_id}`,
  initials: `U${user_id}`,
  bg: `bg-${user_id}`,
  fg: `fg-${user_id}`,
  phx_ref: ref,
});

const state = (...entries: Array<[number, PresenceMeta[]]>): PresenceState =>
  Object.fromEntries(entries.map(([id, metas]) => [String(id), metas]));

/** The wire shape: `{[user_id]: {metas: [...]}}`. */
const wire = (...entries: Array<[number, PresenceMeta[]]>) =>
  Object.fromEntries(entries.map(([id, metas]) => [String(id), { metas }]));

describe("presence_state (item 3.4.2)", () => {
  it("replaces what was held with what the server lists", () => {
    const before = state([1, [meta(1, 10, "a")]], [2, [meta(2, 20, "b")]]);
    const after = applyState(before, wire([2, [meta(2, 21, "c")]], [3, [meta(3, null, "d")]]));

    assert.deepEqual(Object.keys(after), ["2", "3"]);
    assert.deepEqual(after["2"], [meta(2, 21, "c")]);
    assert.deepEqual(after["3"], [meta(3, null, "d")]);
  });

  it("keeps a window it already knows in its place, and adds the new ones after", () => {
    const before = state([1, [meta(1, 10, "a"), meta(1, 11, "b")]]);
    const after = applyState(before, wire([1, [meta(1, 12, "c"), meta(1, 10, "a")]]));

    assert.deepEqual(after["1"], [meta(1, 10, "a"), meta(1, 12, "c")]);
  });

  it("drops a meta it cannot read rather than a whole state", () => {
    const after = applyState(emptyPresence, {
      "1": { metas: [{ user_id: "one" }, meta(1, 10, "a")] },
      "2": { metas: "nope" },
      "3": "nope",
    });

    assert.deepEqual(after, state([1, [meta(1, 10, "a")]]));
  });

  it("reads nothing as nobody", () => {
    assert.deepEqual(applyState(state([1, [meta(1, 10, "a")]]), null), {});
    assert.deepEqual(applyState(state([1, [meta(1, 10, "a")]]), {}), {});
  });
});

describe("presence_diff", () => {
  it("adds a user who joins", () => {
    const after = applyDiff(emptyPresence, { joins: wire([1, [meta(1, null, "a")]]), leaves: {} });
    assert.deepEqual(after, state([1, [meta(1, null, "a")]]));
  });

  it("adds a second window for a user already here", () => {
    const before = state([1, [meta(1, 10, "a")]]);
    const after = applyDiff(before, { joins: wire([1, [meta(1, 11, "b")]]), leaves: {} });
    assert.deepEqual(after["1"], [meta(1, 10, "a"), meta(1, 11, "b")]);
  });

  it("removes only the window that left", () => {
    const before = state([1, [meta(1, 10, "a"), meta(1, 11, "b")]]);
    const after = applyDiff(before, { joins: {}, leaves: wire([1, [meta(1, 10, "a")]]) });
    assert.deepEqual(after["1"], [meta(1, 11, "b")]);
  });

  it("drops a user whose last window leaves", () => {
    const before = state([1, [meta(1, 10, "a")]], [2, [meta(2, 20, "b")]]);
    const after = applyDiff(before, { joins: {}, leaves: wire([1, [meta(1, 10, "a")]]) });
    assert.deepEqual(Object.keys(after), ["2"]);
  });

  it("lands a selection change as a replacement: join first, then leave", () => {
    // `Presence.update` sends the old ref as a leave and the new one as a join,
    // in one diff. Applied in Phoenix's order the user never blinks out.
    const before = state([1, [meta(1, 10, "a")]]);
    const after = applyDiff(before, {
      joins: wire([1, [meta(1, 11, "b")]]),
      leaves: wire([1, [meta(1, 10, "a")]]),
    });
    assert.deepEqual(after, state([1, [meta(1, 11, "b")]]));
  });

  it("matches a meta with no ref by its user and task", () => {
    const bare = { ...meta(1, 10, "x"), phx_ref: undefined } as unknown as PresenceMeta;
    const before = applyDiff(emptyPresence, { joins: wire([1, [bare]]), leaves: {} });
    const after = applyDiff(before, { joins: {}, leaves: wire([1, [bare]]) });
    assert.deepEqual(after, {});
  });

  it("ignores a leave for someone it never saw", () => {
    const before = state([1, [meta(1, 10, "a")]]);
    const after = applyDiff(before, { joins: {}, leaves: wire([9, [meta(9, 1, "z")]]) });
    assert.deepEqual(after, before);
  });

  it("hands the same state back when the diff is empty or unreadable", () => {
    const before = state([1, [meta(1, 10, "a")]]);
    assert.equal(applyDiff(before, { joins: {}, leaves: {} }), before);
    assert.equal(applyDiff(before, null), before);
    assert.equal(applyDiff(before, "diff"), before);
  });
});

describe("the selectors (push_presence/1)", () => {
  const here = state(
    [1, [meta(1, 10, "a"), meta(1, 10, "a2"), meta(1, null, "a3")]],
    [2, [meta(2, 10, "b"), meta(2, 11, "c")]],
    [3, [meta(3, null, "d")]],
  );

  it("lists everyone else's selections, one per user and task", () => {
    const mine = selectionsOf(here, 2);
    assert.deepEqual(
      mine.map((s) => [s.user_id, s.task_id]),
      [[1, 10]],
    );
    assert.deepEqual(mine[0], {
      user_id: 1,
      task_id: 10,
      name: "User 1",
      initials: "U1",
      bg: "bg-1",
      fg: "fg-1",
    });
  });

  it("keeps two selections by the same user on different tasks", () => {
    assert.deepEqual(
      selectionsOf(here, 1).map((s) => [s.user_id, s.task_id]),
      [
        [2, 10],
        [2, 11],
      ],
    );
  });

  it("skips windows with nothing selected", () => {
    assert.deepEqual(selectionsOf(state([3, [meta(3, null, "d")]]), 1), []);
  });

  it("counts everyone here, self included, whatever they have selected", () => {
    assert.deepEqual([...onlineIds(here)].sort(), [1, 2, 3]);
    assert.deepEqual([...onlineIds(emptyPresence)], []);
  });
});

describe("one meta", () => {
  it("reads the server's shape, with or without a ref", () => {
    assert.deepEqual(parseMeta(meta(1, 10, "a")), meta(1, 10, "a"));
    const { phx_ref: _ref, ...bare } = meta(1, null, "a");
    assert.deepEqual(parseMeta(bare), bare);
  });

  it("refuses anything that is not one", () => {
    assert.equal(parseMeta(null), null);
    assert.equal(parseMeta({ ...meta(1, 10, "a"), user_id: "1" }), null);
    assert.equal(parseMeta({ ...meta(1, 10, "a"), task_id: "10" }), null);
    assert.equal(parseMeta({ ...meta(1, 10, "a"), bg: 3 }), null);
  });
});
