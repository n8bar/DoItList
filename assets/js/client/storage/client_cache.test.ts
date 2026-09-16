import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { InitiativeTree } from "../api/types.ts";
import { openClientCache } from "./client_cache.ts";
import type { StorageDegraded, StorageStatus } from "./db.ts";
import { accountDbName } from "./db.ts";
import { FakeIdb } from "./fake_idb.ts";
import type { KeyValueStore } from "./last_user.ts";
import { LAST_USER_KEY, readLastUser } from "./last_user.ts";
import type { SnapshotMeta } from "./snapshots.ts";
import { treeSummary } from "./snapshots.ts";

const USER = 41;
const OTHER = 77;

const fakeStore = (initial: Record<string, string> = {}): KeyValueStore => {
  const map = new Map(Object.entries(initial));
  return {
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    removeItem: (key) => void map.delete(key),
  };
};

const tree = (id = 12, version = 7): InitiativeTree => ({
  id,
  name: `Initiative ${id}`,
  subtitle: null,
  role: "owner",
  progress: 10,
  progress_calc: "leaf_average",
  unit_count: 3,
  index_style: "numeric",
  root_task_id: 1,
  version,
  tasks: [],
});

describe("the tab's cache handle (items 3.4–3.6)", () => {
  it("keeps a write made before the store finished opening", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });

    // Synchronously, one tick after construction: the open has not resolved.
    cache.cacheTree(tree());
    await cache.ready;

    assert.deepEqual(await cache.readTree(12), treeSummary(tree()));
  });

  it("reports the status and the newest snapshot to its listeners", async () => {
    const idb = new FakeIdb();
    const statuses: StorageStatus[] = [];
    const metas: (SnapshotMeta | null)[] = [];
    const cache = openClientCache({
      userId: USER,
      idb,
      keyValue: fakeStore(),
      now: () => 100,
      onStatus: (status: StorageStatus, _reason: StorageDegraded | null) => statuses.push(status),
      onMeta: (meta) => metas.push(meta),
    });

    await cache.ready;
    cache.cacheTree(tree());
    // The write is fire-and-forget by design; let it land before reading back.
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.deepEqual(statuses.at(-1), "ready");
    assert.deepEqual(metas.at(-1), { initiativeId: 12, version: 7, savedAt: 100 });
  });

  it("does nothing at all for a signed-out tab", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: null, idb, keyValue: fakeStore() });

    cache.cacheTree(tree());
    await cache.ready;

    assert.equal(await cache.readTree(12), null);
    assert.equal(idb.databasesByName.size, 0, "a signed-out tab creates no database");
    assert.equal(await cache.purge(), false);
  });

  it("purges on sign-out", async () => {
    const idb = new FakeIdb();
    const keyValue = fakeStore();
    const cache = openClientCache({ userId: USER, idb, keyValue });
    cache.cacheTree(tree());
    await cache.ready;

    assert.equal(await cache.purge(), true);
    assert.equal(idb.databasesByName.has(accountDbName(USER)), false);
    assert.equal(readLastUser(keyValue), null);
  });

  it("throws away the old account's cache when the session turns out to be somebody else", async () => {
    const idb = new FakeIdb();
    const keyValue = fakeStore({ [LAST_USER_KEY]: String(USER) });
    const cache = openClientCache({ userId: USER, idb, keyValue });
    cache.cacheTree(tree());
    await cache.ready;

    await cache.switchTo(OTHER);

    assert.equal(cache.userId(), OTHER);
    assert.equal(idb.databasesByName.has(accountDbName(USER)), false);
    assert.equal(readLastUser(keyValue), OTHER);
    assert.equal(await cache.readTree(12), null, "the new account starts empty");
  });

  it("deletes the snapshot when access to an Initiative is taken away", async () => {
    const idb = new FakeIdb();
    const metas: unknown[] = [];
    const cache = openClientCache({
      userId: USER,
      idb,
      keyValue: fakeStore(),
      onMeta: (meta) => metas.push(meta),
    });
    await cache.writeTree(tree());

    await cache.forgetInitiative(12);

    assert.equal(await cache.readTree(12), null);
    assert.equal(metas.at(-1), null, "the newest-snapshot pointer goes with it");
  });

  it("discards a snapshot that lands after access was taken away", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    await cache.ready;

    // The write is in flight when the revocation arrives.
    const inFlight = cache.writeTree(tree());
    await cache.forgetInitiative(12);
    assert.equal(await inFlight, false, "a write undone is not a write that landed");

    assert.equal(await cache.readTree(12), null);
  });

  it("leaves other Initiatives alone when one is forgotten", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    await cache.writeTree(tree(12));
    await cache.writeTree(tree(13));

    await cache.forgetInitiative(12);

    assert.equal(await cache.readTree(12), null);
    assert.deepEqual(await cache.readTree(13), treeSummary(tree(13)));
  });

  it("does not churn the store when the session confirms the same user", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    cache.cacheTree(tree());
    await cache.ready;

    await cache.switchTo(USER);

    assert.deepEqual(await cache.readTree(12), treeSummary(tree()));
  });
});
