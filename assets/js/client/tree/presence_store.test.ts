import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { Selection } from "../live/presence_model.ts";
import { createPresenceStore, nobodyPresent } from "./presence_store.ts";

const ann = (task_id: number): Selection => ({
  user_id: 2,
  task_id,
  field: null,
  name: "Ann",
  initials: "A",
  bg: "#123",
  fg: "#fff",
});
const bob = (task_id: number): Selection => ({
  user_id: 3,
  task_id,
  field: null,
  name: "Bob",
  initials: "B",
  bg: "#456",
  fg: "#000",
});

describe("presence store (item 7.17)", () => {
  it("starts with nobody", () => {
    assert.deepEqual(nobodyPresent.badges(10), []);
    assert.equal(nobodyPresent.online(2), false);
    assert.equal(nobodyPresent.online(null), false);
    assert.equal(nobodyPresent.onlineIds().size, 0);
  });

  it("a row's badges are the same array back until they change", () => {
    const store = createPresenceStore();
    let notified = 0;
    store.subscribe(() => (notified += 1));

    store.set({ selections: [ann(10), bob(11)], online: new Set([2, 3]) });
    const first = store.badges(10);
    assert.deepEqual(first.map((s) => s.user_id), [2]);
    assert.equal(notified, 1);

    // The same picture, filed again as a new object — my own echo, say.
    store.set({ selections: [ann(10), bob(11)], online: new Set([2, 3]) });
    assert.equal(store.badges(10), first);
    assert.equal(notified, 1);

    // Bob moves: row 11 and row 12 change, row 10 keeps its array.
    const online = store.onlineIds();
    store.set({ selections: [ann(10), bob(12)], online: new Set([2, 3]) });
    assert.equal(store.badges(10), first);
    assert.deepEqual(store.badges(11), []);
    assert.deepEqual(store.badges(12).map((s) => s.user_id), [3]);
    assert.equal(store.onlineIds(), online);
    assert.equal(notified, 2);
  });

  it("the online set is kept while its members are, and answers per user", () => {
    const store = createPresenceStore();
    let notified = 0;
    store.subscribe(() => (notified += 1));

    store.set({ selections: [], online: new Set([2]) });
    const online = store.onlineIds();
    assert.equal(store.online(2), true);
    assert.equal(store.online(3), false);
    assert.equal(store.online(null), false);

    store.set({ selections: [], online: new Set([2]) });
    assert.equal(store.onlineIds(), online);
    assert.equal(notified, 1);

    store.set({ selections: [], online: new Set([2, 3]) });
    assert.equal(store.online(3), true);
    assert.equal(notified, 2);
  });

  it("a row losing its only badge is a change", () => {
    const store = createPresenceStore({ selections: [ann(10)], online: new Set([2]) });
    let notified = 0;
    store.subscribe(() => (notified += 1));
    store.set({ selections: [], online: new Set([2]) });
    assert.deepEqual(store.badges(10), []);
    assert.equal(notified, 1);
  });

  it("unsubscribing stops the notifications", () => {
    const store = createPresenceStore();
    let notified = 0;
    const off = store.subscribe(() => (notified += 1));
    off();
    store.set({ selections: [ann(10)], online: new Set([2]) });
    assert.equal(notified, 0);
  });
});
