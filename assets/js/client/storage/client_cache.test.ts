import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { InitiativeTree } from "../api/types.ts";
import { openClientCache } from "./client_cache.ts";
import type { StorageDegraded, StorageStatus } from "./db.ts";
import { accountDbName } from "./db.ts";
import { FakeIdb } from "./fake_idb.ts";
import type { KeyValueStore } from "./last_user.ts";
import { LAST_USER_KEY, readLastUser } from "./last_user.ts";
import type { PendingOp } from "./pending_ops.ts";
import type { SnapshotMeta } from "./snapshots.ts";
import { fromSnapshot } from "../tree/model.ts";
import type { PendingOpRecord } from "./db.ts";
import { PENDING_OPS, SNAPSHOTS } from "./db.ts";

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

const tree = (id = 12, version = 7) =>
  fromSnapshot({
    id,
    name: `Initiative ${id}`,
    subtitle: null,
    role: "owner",
    progress: 10,
    progress_calc: "leaf_average",
    unit_count: 3,
    index_style: "numerical",
    root_task_id: 1,
    version,
    seq: version,
    tasks: [],
  } satisfies InitiativeTree);

describe("the tab's cache handle (items 3.4–3.6)", () => {
  it("keeps a write made before the store finished opening", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });

    // Synchronously, one tick after construction: the open has not resolved.
    cache.cacheTree(tree());
    await cache.ready;

    assert.deepEqual(await cache.readTree(12), tree());
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
    assert.deepEqual(metas.at(-1), { initiativeId: 12, version: 7, seq: 7, savedAt: 100 });
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
    assert.deepEqual(await cache.readTree(13), tree(13));
  });

  it("does not churn the store when the session confirms the same user", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    cache.cacheTree(tree());
    await cache.ready;

    await cache.switchTo(USER);

    assert.deepEqual(await cache.readTree(12), tree());
  });
});

const queued = (key: string, initiativeId: number, createdAt: number): PendingOpRecord => ({
  key,
  initiativeId,
  createdAt,
  payload: { kind: "write", write: { kind: "toggleComplete", id: 5, done: true }, body: null, status: "queued" },
});

const keys = (records: readonly PendingOp[]) => records.map((record) => record.key);

describe("the queued operations (m04.03 2.1, 2.4)", () => {
  it("keeps what it is handed, oldest first, and tells its listener every time", async () => {
    const idb = new FakeIdb();
    const seen: string[][] = [];
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore(), onPending: (records) => seen.push(keys(records)) });
    await cache.ready;
    assert.deepEqual(seen, [[]], "told once on open, with nothing yet");

    assert.equal(await cache.putPendingOp(queued("b", 12, 20)), true);
    assert.equal(await cache.putPendingOp(queued("a", 12, 10)), true);
    assert.deepEqual(keys(await cache.pendingOps()), ["a", "b"]);
    assert.equal(idb.rows(accountDbName(USER), PENDING_OPS).length, 2, "on the device, not only in memory");

    await cache.deletePendingOp("a");
    assert.deepEqual(keys(await cache.pendingOps()), ["b"]);
    assert.deepEqual(seen.at(-1), ["b"]);
  });

  it("keeps what was queued while the store was still opening", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });

    const first = cache.putPendingOp(queued("early", 12, 10));
    await cache.ready;
    assert.deepEqual(keys(await cache.pendingOps()), ["early"]);
    assert.equal(await first, true);
    assert.equal(idb.rows(accountDbName(USER), PENDING_OPS).length, 1);
  });

  it("reads back what an earlier tab left, and drops a row it cannot read", async () => {
    const idb = new FakeIdb();
    const first = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    await first.putPendingOp(queued("kept", 12, 10));
    first.close();
    await new Promise((resolve) => setTimeout(resolve, 0));
    idb.seedRow(accountDbName(USER), PENDING_OPS, "junk", { key: "junk", initiativeId: 12, createdAt: 11, payload: "??" });

    const seen: string[][] = [];
    const second = openClientCache({ userId: USER, idb, keyValue: fakeStore(), onPending: (records) => seen.push(keys(records)) });
    assert.deepEqual(keys(await second.pendingOps()), ["kept"]);
    assert.deepEqual(seen, [["kept"]]);
    assert.equal(idb.rows(accountDbName(USER), PENDING_OPS).length, 1, "the unreadable row is deleted");
  });

  it("access loss takes the Initiative's queued operations with its snapshot, and nothing else", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    await cache.writeTree(tree(12));
    await cache.writeTree(tree(13));
    await cache.putPendingOp(queued("gone", 12, 10));
    await cache.putPendingOp(queued("kept", 13, 20));

    await cache.forgetInitiative(12);

    assert.equal(await cache.readTree(12), null);
    assert.deepEqual(await cache.readTree(13), tree(13));
    assert.deepEqual(keys(await cache.pendingOps()), ["kept"]);
    assert.deepEqual(idb.rows(accountDbName(USER), PENDING_OPS).map((row) => (row as PendingOpRecord).key), ["kept"]);
  });

  it("a queued operation landing after access went is deleted again", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    await cache.ready;

    const inFlight = cache.putPendingOp(queued("late", 12, 10));
    await cache.forgetInitiative(12);
    assert.equal(await inFlight, false);
    assert.deepEqual(await cache.pendingOps(), []);
    assert.deepEqual(idb.rows(accountDbName(USER), PENDING_OPS), []);
  });

  it("sign-out takes the queue with the database", async () => {
    const idb = new FakeIdb();
    const seen: string[][] = [];
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore(), onPending: (records) => seen.push(keys(records)) });
    await cache.putPendingOp(queued("a", 12, 10));

    assert.equal(await cache.purge(), true);

    assert.equal(idb.databasesByName.has(accountDbName(USER)), false);
    assert.deepEqual(seen.at(-1), []);
    assert.deepEqual(await cache.pendingOps(), []);
  });

  it("a refused write is false, not a throw, and the record still counts on this device", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    await cache.ready;
    idb.failWrites(1);

    assert.equal(await cache.putPendingOp(queued("a", 12, 10)), false);
    assert.deepEqual(keys(await cache.pendingOps()), ["a"], "the memory copy stands in for the session");
  });

  it("deletes a cached tree that does not read back as one", async () => {
    const idb = new FakeIdb();
    const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
    await cache.writeTree(tree(12));
    idb.seedRow(accountDbName(USER), SNAPSHOTS, 12, { initiativeId: 12, seq: 7, savedAt: 1, bytes: 2, payload: { id: 12 } });

    assert.equal(await cache.readTree(12), null);
    assert.deepEqual(idb.rows(accountDbName(USER), SNAPSHOTS), []);
  });
});
