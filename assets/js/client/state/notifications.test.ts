import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  MAX_RECENT,
  emptyNotifications,
  loaded,
  markAllRead,
  prepend,
  restoreUnread,
  unreadCount,
} from "./notifications.ts";
import type { NotificationRow } from "./notifications.ts";

const row = (id: number, read = false, at = "2026-09-16T10:00:00Z"): NotificationRow => ({
  id,
  kind: "assigned",
  line: `Dana assigned you task ${id}`,
  href: `/app/initiatives/1?task=${id}`,
  read,
  inserted_at: at,
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

describe("the read landing after the socket has already spoken", () => {
  it("keeps a row that arrived while the read was in flight, and counts it", () => {
    // The channel is joined before the read comes back, so this ordering is
    // normal, not exotic: push first, answer second. The answer is a snapshot
    // from BEFORE the push, and taking it verbatim would lose the row.
    const pushed = prepend(emptyNotifications, row(9, false, "2026-09-16T11:00:00Z"));
    const state = loaded(pushed, [row(2), row(1, true)], 1);

    assert.deepEqual(
      state.recent.map((n) => n.id),
      [9, 2, 1],
    );
    assert.equal(state.unread, 2);
    assert.equal(state.loaded, true);
  });

  it("lets the server's copy of a row win over the one we were pushed", () => {
    const pushed = prepend(emptyNotifications, row(2, false));
    const state = loaded(pushed, [row(2, true)], 0);

    assert.deepEqual(
      state.recent.map((n) => n.id),
      [2],
    );
    assert.equal(state.recent[0]?.read, true);
    assert.equal(state.unread, 0);
  });

  it("still holds only the newest MAX_RECENT after a merge", () => {
    const many = Array.from({ length: MAX_RECENT }, (_, i) => row(i + 1, true));
    const pushed = prepend(emptyNotifications, row(99, false, "2026-09-16T12:00:00Z"));
    const state = loaded(pushed, many, 0);

    assert.equal(state.recent.length, MAX_RECENT);
    assert.equal(state.recent[0]?.id, 99);
  });
});

describe("putting the dot back when the write failed", () => {
  it("restores only the rows that were unread", () => {
    const before = loaded(emptyNotifications, [row(2), row(1, true)], 1);
    const optimistic = markAllRead(before);
    const rolledBack = restoreUnread(optimistic, [2]);

    assert.equal(rolledBack.unread, 1);
    assert.equal(rolledBack.recent.find((n) => n.id === 2)?.read, false);
    assert.equal(rolledBack.recent.find((n) => n.id === 1)?.read, true);
  });

  it("does not erase a row that arrived during the round trip", () => {
    const before = loaded(emptyNotifications, [row(2)], 1);
    const optimistic = markAllRead(before);
    const during = prepend(optimistic, row(7, false, "2026-09-16T11:00:00Z"));
    const rolledBack = restoreUnread(during, [2]);

    assert.deepEqual(
      rolledBack.recent.map((n) => n.id),
      [7, 2],
    );
    // The new row was never marked read by us, so it keeps its own state and
    // its own place in the count.
    assert.equal(rolledBack.unread, 2);
  });

  it("changes nothing when nothing was unread to begin with", () => {
    const state = loaded(emptyNotifications, [row(1, true)], 0);
    assert.equal(restoreUnread(state, []), state);
  });
});
