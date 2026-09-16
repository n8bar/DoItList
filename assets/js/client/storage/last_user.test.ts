import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { KeyValueStore } from "./last_user.ts";
import { LAST_USER_KEY, clearLastUser, readLastUser, staleAccount, writeLastUser } from "./last_user.ts";

const fakeStore = (initial: Record<string, string> = {}): KeyValueStore & { map: Map<string, string> } => {
  const map = new Map(Object.entries(initial));
  return {
    map,
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    removeItem: (key) => void map.delete(key),
  };
};

const throwingStore = (): KeyValueStore => ({
  getItem: () => {
    throw new Error("blocked");
  },
  setItem: () => {
    throw new Error("blocked");
  },
  removeItem: () => {
    throw new Error("blocked");
  },
});

describe("the last-user marker (item 3.6)", () => {
  it("round-trips a user id", () => {
    const store = fakeStore();
    writeLastUser(store, 41);
    assert.equal(store.map.get(LAST_USER_KEY), "41");
    assert.equal(readLastUser(store), 41);
  });

  it("reads nothing out of an empty or nonsense marker", () => {
    assert.equal(readLastUser(fakeStore()), null);
    assert.equal(readLastUser(fakeStore({ [LAST_USER_KEY]: "" })), null);
    assert.equal(readLastUser(fakeStore({ [LAST_USER_KEY]: "nope" })), null);
    assert.equal(readLastUser(fakeStore({ [LAST_USER_KEY]: "-3" })), null);
  });

  it("clears the marker", () => {
    const store = fakeStore({ [LAST_USER_KEY]: "41" });
    clearLastUser(store);
    assert.equal(readLastUser(store), null);
  });

  it("survives a localStorage that refuses to work", () => {
    const store = throwingStore();
    assert.equal(readLastUser(store), null);
    writeLastUser(store, 41);
    clearLastUser(store);
  });

  it("does nothing at all without a store", () => {
    assert.equal(readLastUser(null), null);
    writeLastUser(null, 41);
    clearLastUser(null);
  });

  it("names the account whose cache has to go", () => {
    assert.equal(staleAccount(77, 41), 77);
    assert.equal(staleAccount(41, 41), null);
    assert.equal(staleAccount(null, 41), null);
  });
});
