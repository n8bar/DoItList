import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { InitiativeTree } from "../api/types.ts";
import {
  PURGE_TIMEOUT_MS,
  openAccountCache,
  purgeAccountCache,
  signOutPurge,
  withTimeout,
} from "./account.ts";
import { accountDbName, createMemoryStorage } from "./db.ts";
import { FakeIdb } from "./fake_idb.ts";
import type { KeyValueStore } from "./last_user.ts";
import { LAST_USER_KEY, readLastUser } from "./last_user.ts";
import { LAST_SNAPSHOT_KEY, createTreeCache, parseTreeModel, treePayload } from "./snapshots.ts";
import { fromSnapshot } from "../tree/model.ts";

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

const read = (overrides: Partial<InitiativeTree> = {}): InitiativeTree => ({
  id: 12,
  name: "Kitchen",
  subtitle: "the long one",
  role: "owner",
  progress: 42,
  progress_calc: "leaf_average",
  unit_count: 9,
  index_style: "numerical",
  root_task_id: 1,
  version: 7,
  seq: 7,
  tasks: [],
  ...overrides,
});

/** One task under the root, so "drops the tree" has a tree to drop. */
const withOneTask = (): InitiativeTree =>
  read({
    tasks: [
      {
        id: 5,
        title: "Paint",
        description: null,
        index: "1",
        position: 0,
        parent_id: 1,
        depth: 0,
        progress: 0,
        manual_progress: 0,
        status: "open",
        done: false,
        leaf: true,
        priority: "normal",
        assignee_id: null,
        co_assignee_ids: [],
        comment_count: 0,
        cross_references: [],
        referenced_by: [],
        sort_mode: null,
        sort_reverse: false,
        updated_by: null,
        updated_at: null,
        version: 1,
        children: [],
      },
    ],
  });

const tree = (overrides: Partial<InitiativeTree> = {}) => fromSnapshot(read(overrides));

const settled = () => new Promise((resolve) => setTimeout(resolve, 0));

describe("opening an account's cache (item 3.4)", () => {
  it("opens this account's store and remembers who it belongs to", async () => {
    const idb = new FakeIdb();
    const keyValue = fakeStore();

    const cache = await openAccountCache({ userId: USER, idb, keyValue });

    assert.equal(cache.storage.kind, "indexeddb");
    assert.equal(readLastUser(keyValue), USER);
    assert.equal(cache.lastSnapshot, null);
    assert.deepEqual(cache.purged, []);
  });

  it("throws away the cache of whoever used this profile last", async () => {
    const idb = new FakeIdb();
    idb.seedDatabase(accountDbName(OTHER), 2, {});
    const keyValue = fakeStore({ [LAST_USER_KEY]: String(OTHER) });

    const cache = await openAccountCache({ userId: USER, idb, keyValue });

    assert.deepEqual(cache.purged, [OTHER]);
    assert.equal(idb.databasesByName.has(accountDbName(OTHER)), false);
    assert.equal(readLastUser(keyValue), USER);
  });

  it("sweeps a stranger's cache even with no marker to go on", async () => {
    const idb = new FakeIdb();
    idb.seedDatabase(accountDbName(OTHER), 2, {});

    const cache = await openAccountCache({ userId: USER, idb, keyValue: fakeStore() });

    assert.deepEqual(cache.purged, [OTHER]);
  });

  it("brings back the newest snapshot's metadata", async () => {
    const idb = new FakeIdb();
    const keyValue = fakeStore();
    const first = await openAccountCache({ userId: USER, idb, keyValue, now: () => 9000 });
    createTreeCache({ storage: first.storage }).cacheTree(tree());
    await settled();
    first.storage.close();

    const second = await openAccountCache({ userId: USER, idb, keyValue });

    assert.deepEqual(second.lastSnapshot, { initiativeId: 12, version: 7, seq: 7, savedAt: 9000 });
  });

  it("still hands back a working cache with no IndexedDB and no localStorage", async () => {
    const cache = await openAccountCache({ userId: USER, idb: null, keyValue: null });

    assert.equal(cache.storage.kind, "memory");
    assert.equal(cache.storage.status(), "unavailable");
    assert.equal(cache.lastSnapshot, null);
  });
});

describe("purging on sign-out (item 3.6)", () => {
  it("deletes the database and forgets the marker", async () => {
    const idb = new FakeIdb();
    const keyValue = fakeStore();
    const cache = await openAccountCache({ userId: USER, idb, keyValue });

    const purged = await purgeAccountCache({
      userId: USER,
      idb,
      keyValue,
      storage: cache.storage,
    });

    assert.equal(purged, true);
    assert.equal(idb.databasesByName.has(accountDbName(USER)), false);
    assert.equal(readLastUser(keyValue), null);
  });

  it("gives up in time rather than trapping the user in the session", async () => {
    const idb = new FakeIdb();
    const keyValue = fakeStore();
    // A delete that never answers: the sign-out must go ahead regardless.
    idb.deleteDatabase = () => ({ result: null, error: null, onsuccess: null, onerror: null });

    const purged = await purgeAccountCache({ userId: USER, idb, keyValue, timeoutMs: 5 });

    assert.equal(purged, false);
    assert.equal(readLastUser(keyValue), null, "the marker goes even when the delete does not");
  });

  it("has a bounded default", () => {
    assert.ok(PURGE_TIMEOUT_MS > 0 && PURGE_TIMEOUT_MS <= 3000);
  });
});

describe("signing out never strands the user (item 3.6)", () => {
  it("purges, then submits", async () => {
    const submitted: number[] = [];
    const purged = await signOutPurge({ purge: () => Promise.resolve(true) }, () =>
      void submitted.push(1),
    );

    assert.equal(purged, true);
    assert.deepEqual(submitted, [1]);
  });

  it("submits anyway when the purge blows up", async () => {
    const submitted: number[] = [];
    const purged = await signOutPurge(
      {
        purge: () => Promise.reject(new Error("the store is on fire")),
      },
      () => submitted.push(1),
    );

    assert.equal(purged, false);
    assert.deepEqual(submitted, [1], "a broken cache must not keep somebody signed in");
  });

  it("submits anyway when the purge throws before it even starts", async () => {
    const submitted: number[] = [];
    await signOutPurge(
      {
        purge: () => {
          throw new Error("no store at all");
        },
      },
      () => submitted.push(1),
    );

    assert.deepEqual(submitted, [1]);
  });

  it("submits anyway when the purge never answers", async () => {
    const submitted: number[] = [];
    const hangs = { purge: () => new Promise<boolean>(() => {}) };
    const purged = await signOutPurge(hangs, () => void submitted.push(1), 5);

    assert.equal(purged, false);
    assert.deepEqual(submitted, [1]);
  });
});

describe("withTimeout", () => {
  it("passes the value through when it is quick enough", async () => {
    assert.equal(await withTimeout(Promise.resolve("done"), 50, "gave up"), "done");
  });

  it("falls back when it is not", async () => {
    assert.equal(await withTimeout(new Promise(() => {}), 5, "gave up"), "gave up");
  });

  it("falls back on a rejection rather than rejecting", async () => {
    assert.equal(await withTimeout(Promise.reject(new Error("no")), 50, "gave up"), "gave up");
  });
});

describe("the Initiative snapshot (item 3.4; m04.03 2.2)", () => {
  it("keeps the whole canonical tree, and reads it back as the same model", () => {
    const model = fromSnapshot(withOneTask());
    const payload = treePayload(model);
    assert.deepEqual(parseTreeModel(structuredClone(payload)), model);
    assert.equal(payload.tasks[5]?.title, "Paint");
    assert.equal(payload.seq, 7);
  });

  it("round-trips through the cache", async () => {
    const storage = createMemoryStorage(USER, "ready", () => 5);
    const cache = createTreeCache({ storage });

    cache.cacheTree(tree());
    await settled();

    assert.deepEqual(await cache.readTree(12), tree());
    assert.deepEqual(
      (await storage.getMeta(LAST_SNAPSHOT_KEY)) as unknown,
      { ok: true, value: { initiativeId: 12, version: 7, seq: 7, savedAt: 5 } },
    );
  });

  it("answers null for an Initiative with nothing cached", async () => {
    const cache = createTreeCache({ storage: createMemoryStorage(USER) });
    assert.equal(await cache.readTree(999), null);
  });

  it("refuses a payload it cannot read rather than inventing a tree", () => {
    assert.equal(parseTreeModel({ id: 1, name: "x" }), null);
    assert.equal(parseTreeModel(null), null);
    assert.equal(parseTreeModel("nope"), null);
    const model = fromSnapshot(withOneTask());
    // The header-only shape v2 kept.
    assert.equal(parseTreeModel({ id: 12, name: "Kitchen", role: "owner", progress: 42, unit_count: 9, version: 7 }), null);
    // Structure that would not pass as a tree: a task listed under nobody.
    assert.equal(parseTreeModel({ ...treePayload(model), childIds: {} }), null);
    assert.equal(parseTreeModel({ ...treePayload(model), progressCalc: "magic" }), null);
  });

  it("deletes a cached record that does not read back as a tree, and answers null", async () => {
    const storage = createMemoryStorage(USER, "ready", () => 5);
    const cache = createTreeCache({ storage });
    await storage.putSnapshot({ initiativeId: 12, seq: 3, payload: { id: 12, name: "old shape" } });

    assert.equal(await cache.readTree(12), null);
    assert.deepEqual(await storage.getSnapshot(12), { ok: true, value: null });
  });

  it("tells its listener what the newest snapshot is", async () => {
    const seen: unknown[] = [];
    const cache = createTreeCache({
      storage: createMemoryStorage(USER, "ready", () => 11),
      onMeta: (meta) => seen.push(meta),
    });

    cache.cacheTree(tree());
    await settled();

    assert.deepEqual(seen, [{ initiativeId: 12, version: 7, seq: 7, savedAt: 11 }]);
  });
});
