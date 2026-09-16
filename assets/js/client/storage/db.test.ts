import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { MAX_SNAPSHOT_AGE_MS } from "./bounds.ts";
import type { StorageDegraded, StorageStatus } from "./db.ts";
import {
  PENDING_OPS,
  SCHEMA_VERSION,
  SNAPSHOTS,
  accountDbName,
  createMemoryStorage,
  openAccountStorage,
  parseDbName,
  payloadBytes,
  META,
  purgeAccountDb,
  purgeAccountDbs,
  purgeOtherAccountDbs,
} from "./db.ts";
import { FakeIdb } from "./fake_idb.ts";

const USER = 41;
const OTHER = 77;
const NAME = accountDbName(USER);

const statusSink = () => {
  const seen: { status: StorageStatus; reason: StorageDegraded | null }[] = [];
  return {
    seen,
    onStatus: (status: StorageStatus, reason: StorageDegraded | null) =>
      seen.push({ status, reason }),
  };
};

const openWith = async (idb: FakeIdb | null, overrides: Record<string, unknown> = {}) =>
  openAccountStorage({ userId: USER, idb, ...overrides });

const unwrap = <T,>(result: { ok: true; value: T } | { ok: false; degraded: StorageDegraded }): T => {
  assert.equal(result.ok, true, `expected a value, got ${JSON.stringify(result)}`);
  return (result as { ok: true; value: T }).value;
};

describe("the account database's name (item 3.4)", () => {
  it("carries the schema version and the user id", () => {
    assert.equal(accountDbName(41), `doit:v${SCHEMA_VERSION}:41`);
    assert.deepEqual(parseDbName(`doit:v${SCHEMA_VERSION}:41`), {
      schema: SCHEMA_VERSION,
      userId: 41,
    });
  });

  it("does not claim names that are not ours", () => {
    assert.equal(parseDbName("keyval-store"), null);
    assert.equal(parseDbName("doit:41"), null);
    assert.equal(parseDbName("doit:vX:41"), null);
  });
});

describe("opening the account database (item 3.4)", () => {
  it("creates the three stores at the current schema version", async () => {
    const idb = new FakeIdb();
    const storage = await openWith(idb);

    assert.equal(storage.kind, "indexeddb");
    assert.equal(storage.status(), "ready");
    const data = idb.databasesByName.get(NAME);
    assert.equal(data?.version, SCHEMA_VERSION);
    for (const store of [SNAPSHOTS, PENDING_OPS, META]) {
      assert.ok(data?.stores.has(store), `missing ${store}`);
    }
  });

  it("migrates a database left at an older schema: snapshots go, pending operations stay", async () => {
    const idb = new FakeIdb();
    idb.seedDatabase(NAME, 1, {
      [SNAPSHOTS]: ["initiativeId", [{ initiativeId: 5, tree: { name: "old shape" } }]],
      [PENDING_OPS]: [
        "key",
        [{ key: "op-1", initiativeId: 5, createdAt: 10, payload: { kind: "rename" } }],
      ],
    });

    const storage = await openWith(idb);

    assert.deepEqual(unwrap(await storage.listSnapshots()), []);
    const pending = unwrap(await storage.listPendingOps());
    assert.equal(pending.length, 1, "an unacknowledged write must survive a migration");
    assert.equal(pending[0]?.key, "op-1");
    assert.ok(idb.databasesByName.get(NAME)?.stores.has(META), "v2 adds the meta store");
  });

  it("falls back to memory, and says so, when there is no IndexedDB at all", async () => {
    const sink = statusSink();
    const storage = await openWith(null, { onStatus: sink.onStatus });

    assert.equal(storage.kind, "memory");
    assert.equal(storage.status(), "unavailable");
    assert.deepEqual(sink.seen[0]?.status, "unavailable");
    // It still works — this tab just has no durable recovery.
    await storage.putSnapshot({ initiativeId: 1, seq: 3, payload: { name: "x" } });
    assert.equal(unwrap(await storage.getSnapshot(1))?.seq, 3);
  });

  it("falls back to memory when the open is refused", async () => {
    const idb = new FakeIdb();
    idb.openFailure = { name: "InvalidStateError", message: "private mode" };
    const sink = statusSink();

    const storage = await openWith(idb, { onStatus: sink.onStatus });

    assert.equal(storage.kind, "memory");
    assert.equal(storage.status(), "unavailable");
    assert.equal(sink.seen[0]?.reason?.kind, "unavailable");
  });

  it("falls back to memory when a newer schema is already in the profile", async () => {
    const idb = new FakeIdb();
    idb.seedDatabase(NAME, SCHEMA_VERSION + 5, {});

    const storage = await openWith(idb);

    assert.equal(storage.kind, "memory");
    assert.equal(storage.status(), "unavailable");
  });

  it("stands aside when another tab needs a newer schema", async () => {
    const idb = new FakeIdb();
    const sink = statusSink();
    const storage = await openWith(idb, { onStatus: sink.onStatus });
    assert.equal(storage.status(), "ready");

    // Another tab asks for a schema we do not have: the browser tells every
    // open connection, and ours must let go rather than block it.
    const blocked = idb.open(NAME, SCHEMA_VERSION + 1);
    await new Promise((resolve) => setTimeout(resolve, 0));

    assert.equal(storage.status(), "unavailable");
    assert.equal(sink.seen.at(-1)?.status, "unavailable");
    // Our connection let go, so the other tab's upgrade was not blocked.
    assert.equal(idb.databasesByName.get(NAME)?.version, SCHEMA_VERSION + 1);
    assert.ok(blocked !== null);
    const refused = await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });
    assert.equal(refused.ok, false, "a closed store refuses writes instead of throwing");
  });

  it("falls back to memory when an upgrade is blocked by another connection", async () => {
    const idb = new FakeIdb();
    // A connection from a tab that will NOT get out of the way.
    idb.seedDatabase(accountDbName(USER), 1, {});
    const stubborn = idb.open(NAME, 1);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(idb.openConnections(NAME), 1);
    assert.ok(stubborn !== null);

    const storage = await openWith(idb, { openTimeoutMs: 50 });

    assert.equal(storage.kind, "memory");
    assert.equal(storage.status(), "unavailable");
  });

  it("gives up on an open that never answers rather than hanging the boot", async () => {
    const idb = new FakeIdb();
    idb.openHangs = true;

    const storage = await openWith(idb, { openTimeoutMs: 5 });

    assert.equal(storage.kind, "memory");
  });
});

describe("account isolation (item 3.4)", () => {
  it("deletes another account's cache and this account's older schemas", async () => {
    const idb = new FakeIdb();
    idb.seedDatabase(accountDbName(OTHER), SCHEMA_VERSION, {});
    idb.seedDatabase(accountDbName(USER, 1), 1, {});
    idb.seedDatabase(NAME, SCHEMA_VERSION, {});
    idb.seedDatabase("someone-elses-library", 3, {});

    const deleted = await purgeOtherAccountDbs(USER, idb);

    assert.deepEqual(deleted.sort(), [accountDbName(OTHER), accountDbName(USER, 1)].sort());
    assert.ok(idb.databasesByName.has(NAME), "our own database stays");
    assert.ok(idb.databasesByName.has("someone-elses-library"), "other apps are left alone");
  });

  it("does nothing, and throws nothing, where databases() is unavailable", async () => {
    const idb = new FakeIdb({ enumerable: false });
    idb.seedDatabase(accountDbName(OTHER), SCHEMA_VERSION, {});

    assert.deepEqual(await purgeOtherAccountDbs(USER, idb), []);
  });

  it("two accounts in one profile never see each other's snapshots", async () => {
    const idb = new FakeIdb();
    const mine = await openAccountStorage({ userId: USER, idb });
    await mine.putSnapshot({ initiativeId: 9, seq: 1, payload: { name: "mine" } });
    mine.close();

    const theirs = await openAccountStorage({ userId: OTHER, idb });
    assert.equal(unwrap(await theirs.getSnapshot(9)), null);
  });
});

describe("snapshots and meta (items 3.4, 3.6)", () => {
  it("round-trips a snapshot with its size and time recorded", async () => {
    const idb = new FakeIdb();
    const storage = await openWith(idb, { now: () => 5000 });
    const payload = { name: "Kitchen", progress: 42 };

    await storage.putSnapshot({ initiativeId: 3, seq: 12, payload });

    const stored = unwrap(await storage.getSnapshot(3));
    assert.equal(stored?.seq, 12);
    assert.equal(stored?.savedAt, 5000);
    assert.equal(stored?.bytes, payloadBytes(payload));
    assert.deepEqual(stored?.payload, payload);
  });

  it("answers null for an Initiative it has never cached", async () => {
    const storage = await openWith(new FakeIdb());
    assert.equal(unwrap(await storage.getSnapshot(404)), null);
  });

  it("round-trips meta values", async () => {
    const storage = await openWith(new FakeIdb());
    await storage.putMeta("last_initiative", 12);
    assert.equal(unwrap(await storage.getMeta("last_initiative")), 12);
    assert.equal(unwrap(await storage.getMeta("never_written")), null);
  });

  it("deletes a meta row it cannot read, exactly like a snapshot", async () => {
    const idb = new FakeIdb();
    const storage = await openWith(idb);
    idb.seedRow(NAME, META, "last_snapshot", "not a record at all");

    assert.equal(unwrap(await storage.getMeta("last_snapshot")), null);
    assert.equal(storage.status(), "degraded");
    assert.deepEqual(idb.rows(NAME, META), []);
  });
});

describe("bounds enforcement in the store (item 3.5)", () => {
  it("evicts stale snapshots at boot and after a write", async () => {
    const idb = new FakeIdb();
    let clock = 0;
    const storage = await openWith(idb, { now: () => clock });

    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });
    clock = MAX_SNAPSHOT_AGE_MS + 1;

    const evicted = unwrap(await storage.enforceBounds());
    assert.deepEqual(evicted, [1]);
    assert.equal(unwrap(await storage.getSnapshot(1)), null);
  });

  it("evicts the oldest when there are too many, keeping the one just written", async () => {
    const idb = new FakeIdb();
    let clock = 1000;
    const storage = await openWith(idb, {
      now: () => (clock += 10),
      limits: { maxAgeMs: MAX_SNAPSHOT_AGE_MS, maxTotalBytes: 1_000_000, maxSnapshots: 2 },
    });

    for (const id of [1, 2, 3]) {
      await storage.putSnapshot({ initiativeId: id, seq: id, payload: { id } });
    }

    const held = unwrap(await storage.listSnapshots()).map((r) => r.initiativeId).sort();
    assert.deepEqual(held, [2, 3]);
  });

  it("evicts to fit the byte budget", async () => {
    const idb = new FakeIdb();
    let clock = 1000;
    const storage = await openWith(idb, {
      now: () => (clock += 10),
      limits: { maxAgeMs: MAX_SNAPSHOT_AGE_MS, maxTotalBytes: 60, maxSnapshots: 50 },
    });

    for (const id of [1, 2, 3]) {
      await storage.putSnapshot({ initiativeId: id, seq: 1, payload: { text: "x".repeat(30) } });
    }

    const held = unwrap(await storage.listSnapshots());
    assert.equal(held.length, 1);
    assert.equal(held[0]?.initiativeId, 3);
  });

  it("never evicts an unacknowledged operation to make room", async () => {
    const idb = new FakeIdb();
    let clock = 0;
    const storage = await openWith(idb, { now: () => clock });
    idb.seedRow(NAME, PENDING_OPS, "op-9", {
      key: "op-9",
      initiativeId: 1,
      createdAt: 0,
      payload: { kind: "complete" },
    });
    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });

    clock = MAX_SNAPSHOT_AGE_MS * 10;
    await storage.enforceBounds();

    assert.deepEqual(unwrap(await storage.listSnapshots()), []);
    assert.equal(unwrap(await storage.listPendingOps()).length, 1);
  });
});

describe("quota refusal (item 3.5)", () => {
  it("evicts the oldest and retries once, and the write lands", async () => {
    const idb = new FakeIdb();
    let clock = 1000;
    const storage = await openWith(idb, { now: () => (clock += 10) });
    for (const id of [1, 2, 3, 4]) {
      await storage.putSnapshot({ initiativeId: id, seq: 1, payload: { id } });
    }

    idb.failWrites(1);
    const result = await storage.putSnapshot({ initiativeId: 5, seq: 1, payload: { id: 5 } });

    assert.equal(result.ok, true);
    assert.equal(unwrap(await storage.getSnapshot(5))?.seq, 1);
    assert.equal(unwrap(await storage.getSnapshot(1)), null, "the oldest made room");
  });

  it("degrades instead of throwing when the retry is refused too", async () => {
    const idb = new FakeIdb();
    const sink = statusSink();
    const storage = await openWith(idb, { onStatus: sink.onStatus });
    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { id: 1 } });

    idb.failWrites(20);
    const result = await storage.putSnapshot({ initiativeId: 2, seq: 1, payload: { id: 2 } });

    assert.equal(result.ok, false);
    assert.equal(result.ok === false && result.degraded.kind, "quota");
    assert.equal(storage.status(), "degraded");
    assert.equal(sink.seen.at(-1)?.status, "degraded");
  });
});

describe("corrupt records (item 3.6)", () => {
  it("deletes a record it cannot read rather than re-reading it forever", async () => {
    const idb = new FakeIdb();
    const sink = statusSink();
    const storage = await openWith(idb, { onStatus: sink.onStatus });
    idb.seedRow(NAME, SNAPSHOTS, 6, { initiativeId: 6, payload: "half a record" });

    assert.equal(unwrap(await storage.getSnapshot(6)), null);
    assert.equal(storage.status(), "degraded");
    assert.deepEqual(idb.rows(NAME, SNAPSHOTS), []);
  });

  it("drops corrupt rows from a listing and keeps the good ones", async () => {
    const idb = new FakeIdb();
    const storage = await openWith(idb);
    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });
    idb.seedRow(NAME, SNAPSHOTS, 2, { initiativeId: 2, junk: true });

    const held = unwrap(await storage.listSnapshots());

    assert.deepEqual(held.map((r) => r.initiativeId), [1]);
    assert.equal(idb.rows(NAME, SNAPSHOTS).length, 1);
  });
});

describe("purging (item 3.6)", () => {
  it("deletes this account's database", async () => {
    const idb = new FakeIdb();
    const storage = await openWith(idb);
    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });
    storage.close();

    assert.equal(await purgeAccountDb(USER, idb), true);
    assert.equal(idb.databasesByName.has(NAME), false);
  });

  it("resolves false, not rejected, where there is no IndexedDB", async () => {
    assert.equal(await purgeAccountDb(USER, null), false);
  });

  it("deletes this account's older schemas too, not just the current one", async () => {
    const idb = new FakeIdb();
    idb.seedDatabase(accountDbName(USER, 1), 1, {});
    idb.seedDatabase(accountDbName(USER), SCHEMA_VERSION, {});
    idb.seedDatabase(accountDbName(OTHER, 1), 1, {});

    assert.equal(await purgeAccountDbs(USER, idb), true);

    assert.equal(idb.databasesByName.has(accountDbName(USER, 1)), false);
    assert.equal(idb.databasesByName.has(accountDbName(USER)), false);
    assert.ok(idb.databasesByName.has(accountDbName(OTHER, 1)), "other accounts are not ours to delete here");
  });

  it("waits for the open connection it just told to close", async () => {
    const idb = new FakeIdb();
    const storage = await openWith(idb);
    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });

    // No explicit close: the delete fires `versionchange`, the store closes
    // itself, and only then does the delete go through.
    assert.equal(await purgeAccountDb(USER, idb), true);
    assert.equal(idb.databasesByName.has(NAME), false);
    assert.equal(storage.status(), "unavailable");
  });
});

describe("the in-memory fallback (item 3.6)", () => {
  it("honours the same bounds", async () => {
    let clock = 0;
    const storage = createMemoryStorage(USER, "unavailable", () => clock);
    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });

    clock = MAX_SNAPSHOT_AGE_MS + 1;
    assert.deepEqual(unwrap(await storage.enforceBounds()), [1]);
    assert.equal(unwrap(await storage.getSnapshot(1)), null);
  });

  it("forgets everything when it is closed", async () => {
    const storage = createMemoryStorage(USER);
    await storage.putSnapshot({ initiativeId: 1, seq: 1, payload: { a: 1 } });
    storage.close();
    assert.equal(unwrap(await storage.getSnapshot(1)), null);
  });
});
