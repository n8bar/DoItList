import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  MAX_RECENT,
  emptyNotifications,
  loaded,
  markAllRead,
  prepend,
  unreadCount,
} from "./notifications.ts";
import type { NotificationRow } from "./notifications.ts";

const row = (id: number, read = false): NotificationRow => ({
  id,
  kind: "assigned",
  line: `Dana assigned you task ${id}`,
  href: `/app/initiatives/1?task=${id}`,
  read,
  inserted_at: "2026-09-16T10:00:00Z",
});

describe("what the bell holds", () => {
  it("starts empty, unread zero, and says it has not read yet", () => {
    assert.deepEqual(emptyNotifications.recent, []);
    assert.equal(emptyNotifications.unread, 0);
    assert.equal(emptyNotifications.loaded, false);
  });

  it("takes the server's list and count verbatim", () => {
    const state = loaded(emptyNotifications, [row(2), row(1, true)], 1);
    assert.equal(state.loaded, true);
    assert.deepEqual(
      state.recent.map((n) => n.id),
      [2, 1],
    );
    assert.equal(state.unread, 1);
  });
});

describe("a notification arriving over the socket", () => {
  it("goes on top and bumps the unread count", () => {
    const state = prepend(loaded(emptyNotifications, [row(1)], 1), row(2));
    assert.deepEqual(
      state.recent.map((n) => n.id),
      [2, 1],
    );
    assert.equal(state.unread, 2);
  });

  it("is not counted twice when the same row arrives again", () => {
    const once = prepend(loaded(emptyNotifications, [], 0), row(2));
    const twice = prepend(once, row(2));
    assert.deepEqual(
      twice.recent.map((n) => n.id),
      [2],
    );
    assert.equal(twice.unread, 1);
  });

  it("an already-read row does not raise the count", () => {
    const state = prepend(loaded(emptyNotifications, [], 0), row(2, true));
    assert.equal(state.unread, 0);
  });

  it("keeps the list to the same cap the server sends", () => {
    let state = loaded(emptyNotifications, [], 0);
    for (let id = 1; id <= MAX_RECENT + 5; id += 1) state = prepend(state, row(id));
    assert.equal(state.recent.length, MAX_RECENT);
    assert.equal(state.recent[0]?.id, MAX_RECENT + 5);
  });
});

describe("marking everything read", () => {
  it("clears the count and every row, in one step the client can show at once", () => {
    const before = loaded(emptyNotifications, [row(2), row(1, true)], 1);
    const after = markAllRead(before);
    assert.equal(after.unread, 0);
    assert.ok(after.recent.every((n) => n.read));
  });

  it("leaves the previous value untouched, so a failed write can put it back", () => {
    const before = loaded(emptyNotifications, [row(2)], 1);
    const after = markAllRead(before);
    assert.equal(before.unread, 1);
    assert.equal(before.recent[0]?.read, false);
    assert.notEqual(after, before);
  });

  it("changes nothing when there was nothing unread", () => {
    const before = loaded(emptyNotifications, [row(1, true)], 0);
    assert.equal(markAllRead(before), before);
  });
});

describe("unreadCount", () => {
  it("counts the rows that have not been read", () => {
    assert.equal(unreadCount([row(1), row(2, true), row(3)]), 2);
  });
});
