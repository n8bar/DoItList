// The account-scoped recovery cache (m04.01 items 3.4–3.6).
//
// One database per signed-in user, named for the schema AND the user id, so a
// shared browser profile can hold two accounts' caches without either one ever
// reading the other's (spec §12). On boot every other `doit:` database — another
// account's, or this account's under an older schema — is deleted.
//
// The cache is bounded (bounds.ts) and disposable. Everything that can go wrong
// with it — no IndexedDB at all, a blocked or version-conflicted open, a quota
// refusal, a record that comes back unreadable — resolves to a working store
// with a degraded status, never to a thrown error in a render. A client with no
// trustworthy snapshot serves nothing rather than inventing one (spec §5).

import type { BoundLimits, BoundedRecord } from "./bounds.ts";
import { DEFAULT_LIMITS, evictionPlan, quotaEvictionPlan } from "./bounds.ts";
import type { IdbDatabaseLike, IdbFactoryLike, IdbTransactionLike } from "./idb.ts";
import { committed, request } from "./idb.ts";

/** Bump when a store or a record shape changes. It is in the database name. */
export const SCHEMA_VERSION = 3;

export const DB_PREFIX = "doit:v";
export const SNAPSHOTS = "snapshots";
export const PENDING_OPS = "pending_ops";
export const META = "meta";

/** `doit:v2:41`. The user id is in the name; isolation is not a runtime check. */
export function accountDbName(userId: number, schema: number = SCHEMA_VERSION): string {
  return `${DB_PREFIX}${schema}:${userId}`;
}

/** Reads one of our names back. `null` for anything that isn't ours. */
export function parseDbName(name: string): { schema: number; userId: number } | null {
  const match = /^doit:v(\d+):(\d+)$/.exec(name);
  if (match === null) return null;
  const [, schema, userId] = match;
  if (schema === undefined || userId === undefined) return null;
  return { schema: Number(schema), userId: Number(userId) };
}

export interface SnapshotRecord {
  readonly initiativeId: number;
  /** The Initiative's delivery sequence this snapshot is current to. */
  readonly seq: number;
  readonly savedAt: number;
  readonly bytes: number;
  /** The whole canonical tree (`snapshots.ts` says what shape). */
  readonly payload: unknown;
}

/** One queued operation. The key is its idempotency key; `pending_ops.ts` says what the payload is. */
export interface PendingOpRecord {
  readonly key: string;
  readonly initiativeId: number;
  readonly createdAt: number;
  readonly payload: unknown;
}

export interface MetaRecord {
  readonly key: string;
  readonly value: unknown;
}

/**
 * `ready` — writes land. `degraded` — the store is there but has refused
 * something (quota, a corrupt record); what it holds is still usable.
 * `unavailable` — there is no durable store at all and this session's cache
 * dies with the tab.
 */
export type StorageStatus = "ready" | "degraded" | "unavailable";

export interface StorageDegraded {
  readonly kind: "quota" | "unavailable" | "corrupt" | "failed";
  readonly message: string;
}

export type StorageResult<T> = { ok: true; value: T } | { ok: false; degraded: StorageDegraded };

const ok = <T,>(value: T): StorageResult<T> => ({ ok: true, value });
const degraded = <T,>(kind: StorageDegraded["kind"], message: string): StorageResult<T> => ({
  ok: false,
  degraded: { kind, message },
});

export interface SnapshotInput {
  readonly initiativeId: number;
  readonly seq: number;
  readonly payload: unknown;
  /** Defaults to the storage's clock. */
  readonly savedAt?: number;
}

/**
 * Everything the client is allowed to do with the cache. The IndexedDB-backed
 * store and the in-memory fallback both satisfy it, so nothing upstream has to
 * ask which one it got.
 */
export interface AccountStorage {
  readonly kind: "indexeddb" | "memory";
  readonly userId: number;
  status(): StorageStatus;
  putSnapshot(input: SnapshotInput): Promise<StorageResult<SnapshotRecord>>;
  getSnapshot(initiativeId: number): Promise<StorageResult<SnapshotRecord | null>>;
  listSnapshots(): Promise<StorageResult<SnapshotRecord[]>>;
  deleteSnapshot(initiativeId: number): Promise<StorageResult<void>>;
  getMeta(key: string): Promise<StorageResult<unknown>>;
  putMeta(key: string, value: unknown): Promise<StorageResult<void>>;
  /** Every queued operation, in no particular order. Nothing evicts them. */
  listPendingOps(): Promise<StorageResult<PendingOpRecord[]>>;
  /** Writes (or rewrites) one queued operation under its key. */
  putPendingOp(record: PendingOpRecord): Promise<StorageResult<void>>;
  /** The outcome is known: the record goes. */
  deletePendingOp(key: string): Promise<StorageResult<void>>;
  /** Access to an Initiative is gone: everything queued for it goes. */
  deletePendingOps(initiativeId: number): Promise<StorageResult<void>>;
  /** Applies the age/count/byte bounds. Resolves with what it dropped. */
  enforceBounds(keep?: number | null): Promise<StorageResult<number[]>>;
  close(): void;
}

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

/**
 * Every version step, in order, as its own case. A browser arriving from an
 * older schema runs the steps it missed; a brand new database runs all of them.
 * Deterministic either way — no "whatever the browser had" is ever carried
 * forward untouched.
 */
export function upgradeSchema(
  db: IdbDatabaseLike,
  tx: IdbTransactionLike | null,
  oldVersion: number,
  newVersion: number = SCHEMA_VERSION,
): void {
  const ensure = (name: string, keyPath: string) => {
    if (!db.objectStoreNames.contains(name)) db.createObjectStore(name, { keyPath });
  };

  for (let version = oldVersion + 1; version <= newVersion; version += 1) {
    switch (version) {
      case 1:
        ensure(SNAPSHOTS, "initiativeId");
        ensure(PENDING_OPS, "key");
        break;
      case 2:
        // v2 added `meta` and put `seq`/`bytes` on every snapshot. A v1
        // snapshot cannot be migrated into that shape (the fields were never
        // written), so it is cleared: the client re-reads from the server.
        // Unacknowledged operations are kept — they are the user's work.
        ensure(META, "key");
        if (tx !== null && db.objectStoreNames.contains(SNAPSHOTS)) {
          tx.objectStore(SNAPSHOTS).clear();
        }
        break;
      case 3:
        // v3 caches the whole canonical tree where v2 cached the header only
        // (m04.03 2.2). A v2 payload is not a tree, so it is cleared and
        // re-read from the server. Queued operations are kept, as ever.
        if (tx !== null && db.objectStoreNames.contains(SNAPSHOTS)) {
          tx.objectStore(SNAPSHOTS).clear();
        }
        break;
      default:
        break;
    }
  }
}

// ---------------------------------------------------------------------------
// Record validation — a corrupt record is deleted, never re-read forever
// ---------------------------------------------------------------------------

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export function parseSnapshot(value: unknown): SnapshotRecord | null {
  if (!isRecord(value)) return null;
  const { initiativeId, seq, savedAt, bytes, payload } = value;
  if (
    typeof initiativeId !== "number" ||
    !Number.isFinite(initiativeId) ||
    typeof seq !== "number" ||
    typeof savedAt !== "number" ||
    typeof bytes !== "number" ||
    payload === undefined
  ) {
    return null;
  }
  return { initiativeId, seq, savedAt, bytes, payload };
}

export function parsePendingOp(value: unknown): PendingOpRecord | null {
  if (!isRecord(value)) return null;
  const { key, initiativeId, createdAt, payload } = value;
  if (typeof key !== "string" || typeof initiativeId !== "number" || typeof createdAt !== "number") {
    return null;
  }
  return { key, initiativeId, createdAt, payload };
}

/** What a payload costs us. Cheap and approximate; the bound is a bound. */
export function payloadBytes(payload: unknown): number {
  try {
    return JSON.stringify(payload)?.length ?? 0;
  } catch {
    return 0;
  }
}

// ---------------------------------------------------------------------------
// Opening
// ---------------------------------------------------------------------------

export interface OpenOptions {
  readonly userId: number;
  readonly idb: IdbFactoryLike | null;
  readonly now?: () => number;
  readonly limits?: BoundLimits;
  /** Told whenever the status changes, with the reason when it worsened. */
  readonly onStatus?: (status: StorageStatus, reason: StorageDegraded | null) => void;
  /** Milliseconds to wait for an open that is blocked by another tab. */
  readonly openTimeoutMs?: number;
}

const OPEN_TIMEOUT_MS = 4000;

function openDatabase(
  idb: IdbFactoryLike,
  name: string,
  timeoutMs: number,
): Promise<IdbDatabaseLike> {
  return new Promise<IdbDatabaseLike>((resolve, reject) => {
    let settled = false;
    const finish = (run: () => void) => {
      if (settled) return;
      settled = true;
      run();
    };

    let req;
    try {
      req = idb.open(name, SCHEMA_VERSION);
    } catch (error) {
      reject(error instanceof Error ? error : new Error("IndexedDB refused to open."));
      return;
    }

    const timer = setTimeout(
      () => finish(() => reject(new Error("The local store did not open in time."))),
      timeoutMs,
    );
    const done = (run: () => void) => {
      clearTimeout(timer);
      finish(run);
    };

    req.onupgradeneeded = (event) => {
      // Throwing here would abort the upgrade; let it reject through onerror.
      upgradeSchema(req.result, req.transaction, event.oldVersion);
    };
    req.onsuccess = () => done(() => resolve(req.result));
    req.onerror = () =>
      done(() => reject(new Error(req.error?.message ?? "The local store could not be opened.")));
    // Another tab is holding the old version open. Don't hang the boot on it.
    req.onblocked = () => done(() => reject(new Error("The local store is busy in another tab.")));
  });
}

/**
 * Opens (or creates) this account's cache. Never rejects: a browser without a
 * usable IndexedDB gets the in-memory store and an `unavailable` status, and the
 * client says so rather than pretending it has durable recovery.
 */
export async function openAccountStorage(options: OpenOptions): Promise<AccountStorage> {
  const { userId, idb } = options;
  const notify = options.onStatus ?? (() => {});

  if (idb === null) {
    notify("unavailable", { kind: "unavailable", message: "This browser has no local store." });
    return createMemoryStorage(userId, "unavailable");
  }

  try {
    const db = await openDatabase(idb, accountDbName(userId), options.openTimeoutMs ?? OPEN_TIMEOUT_MS);
    return createIdbStorage(db, options);
  } catch (error) {
    // Private mode, a VersionError from a newer schema in another tab, a
    // blocked upgrade: all the same answer. This session keeps its cache in
    // memory and the UI is told it has no durable recovery.
    const message = error instanceof Error ? error.message : "The local store is unavailable.";
    notify("unavailable", { kind: "unavailable", message });
    return createMemoryStorage(userId, "unavailable");
  }
}

// ---------------------------------------------------------------------------
// The IndexedDB-backed store
// ---------------------------------------------------------------------------

function createIdbStorage(db: IdbDatabaseLike, options: OpenOptions): AccountStorage {
  const now = options.now ?? (() => Date.now());
  const limits = options.limits ?? DEFAULT_LIMITS;
  const notify = options.onStatus ?? (() => {});
  let status: StorageStatus = "ready";
  let closed = false;

  const worsen = (reason: StorageDegraded) => {
    if (status === "ready") {
      status = "degraded";
      notify(status, reason);
    }
  };

  // Another tab wants a newer schema: get out of its way rather than block it.
  db.onversionchange = () => {
    closed = true;
    status = "unavailable";
    db.close();
    notify(status, { kind: "unavailable", message: "The local store was replaced in another tab." });
  };

  function read(store: string): Promise<unknown[]> {
    const tx = db.transaction(store, "readonly");
    return request(tx.objectStore(store).getAll());
  }

  async function write<T>(
    store: string,
    run: (objectStore: ReturnType<IdbTransactionLike["objectStore"]>) => void,
    value: T,
  ): Promise<StorageResult<T>> {
    if (closed) return degraded<T>("unavailable", "The local store is closed.");
    try {
      const tx = db.transaction(store, "readwrite");
      const settled = committed(tx);
      run(tx.objectStore(store));
      await settled;
      return ok(value);
    } catch (error) {
      const name = error instanceof Error ? error.name : "UnknownError";
      const message = error instanceof Error ? error.message : "The write failed.";
      if (name === "QuotaExceededError") return degraded<T>("quota", message);
      worsen({ kind: "failed", message });
      return degraded<T>("failed", message);
    }
  }

  async function bounded(records: SnapshotRecord[], keep: number | null): Promise<number[]> {
    const plan = evictionPlan(records, now(), limits, keep);
    for (const id of plan) await write(SNAPSHOTS, (store) => store.delete(id), undefined);
    return plan;
  }

  async function snapshots(): Promise<{ live: SnapshotRecord[]; corrupt: number }> {
    const rows = await read(SNAPSHOTS);
    const live: SnapshotRecord[] = [];
    const corrupt: unknown[] = [];
    for (const row of rows) {
      const parsed = parseSnapshot(row);
      if (parsed === null) corrupt.push(row);
      else live.push(parsed);
    }
    for (const row of corrupt) {
      const key = isRecord(row) ? row["initiativeId"] : undefined;
      if (typeof key === "number") await write(SNAPSHOTS, (store) => store.delete(key), undefined);
    }
    if (corrupt.length > 0) {
      worsen({ kind: "corrupt", message: "Some cached data was unreadable and was discarded." });
    }
    return { live, corrupt: corrupt.length };
  }

  const storage: AccountStorage = {
    kind: "indexeddb",
    userId: options.userId,
    status: () => status,

    async putSnapshot(input) {
      const record: SnapshotRecord = {
        initiativeId: input.initiativeId,
        seq: input.seq,
        savedAt: input.savedAt ?? now(),
        bytes: payloadBytes(input.payload),
        payload: input.payload,
      };

      const first = await write(SNAPSHOTS, (store) => store.put(record), record);
      if (first.ok) {
        await storage.enforceBounds(record.initiativeId);
        return first;
      }
      if (first.degraded.kind !== "quota") return first;

      // The browser said no. Drop the oldest snapshots and try exactly once
      // more; still no means the cache is degraded and the UI gets told —
      // it must never mean a thrown error in the middle of a write.
      const held = await snapshots();
      for (const id of quotaEvictionPlan(held.live, record.initiativeId)) {
        await write(SNAPSHOTS, (store) => store.delete(id), undefined);
      }
      const retry = await write(SNAPSHOTS, (store) => store.put(record), record);
      if (!retry.ok) worsen(retry.degraded);
      return retry;
    },

    async getSnapshot(initiativeId) {
      try {
        const tx = db.transaction(SNAPSHOTS, "readonly");
        const row = await request(tx.objectStore(SNAPSHOTS).get(initiativeId));
        if (row === undefined || row === null) return ok(null);
        const parsed = parseSnapshot(row);
        if (parsed !== null) return ok(parsed);
        await write(SNAPSHOTS, (store) => store.delete(initiativeId), undefined);
        worsen({ kind: "corrupt", message: "A cached Initiative was unreadable and was discarded." });
        return ok(null);
      } catch (error) {
        const message = error instanceof Error ? error.message : "The read failed.";
        worsen({ kind: "failed", message });
        return degraded<SnapshotRecord | null>("failed", message);
      }
    },

    async listSnapshots() {
      try {
        return ok((await snapshots()).live);
      } catch (error) {
        const message = error instanceof Error ? error.message : "The read failed.";
        worsen({ kind: "failed", message });
        return degraded<SnapshotRecord[]>("failed", message);
      }
    },

    deleteSnapshot: (initiativeId) =>
      write(SNAPSHOTS, (store) => store.delete(initiativeId), undefined),

    async getMeta(key) {
      try {
        const tx = db.transaction(META, "readonly");
        const row = await request(tx.objectStore(META).get(key));
        if (row === undefined || row === null) return ok(null);
        if (!isRecord(row)) {
          // Same rule as a corrupt snapshot: delete it, don't re-read it.
          await write(META, (store) => store.delete(key), undefined);
          worsen({ kind: "corrupt", message: "A cached setting was unreadable and was discarded." });
          return ok(null);
        }
        return ok(row["value"]);
      } catch (error) {
        const message = error instanceof Error ? error.message : "The read failed.";
        worsen({ kind: "failed", message });
        return degraded<unknown>("failed", message);
      }
    },

    putMeta: (key, value) =>
      write(META, (store) => store.put({ key, value } satisfies MetaRecord), undefined),

    async listPendingOps() {
      try {
        const rows = await read(PENDING_OPS);
        const live: PendingOpRecord[] = [];
        let corrupt = 0;
        for (const row of rows) {
          const parsed = parsePendingOp(row);
          if (parsed !== null) {
            live.push(parsed);
            continue;
          }
          // Same rule as a corrupt snapshot: a row that cannot be read is
          // deleted, not re-read forever — and there is nothing to replay.
          corrupt += 1;
          const key = isRecord(row) ? row["key"] : undefined;
          if (typeof key === "string") await write(PENDING_OPS, (store) => store.delete(key), undefined);
        }
        if (corrupt > 0) {
          worsen({ kind: "corrupt", message: "Some queued changes were unreadable and were discarded." });
        }
        return ok(live);
      } catch (error) {
        const message = error instanceof Error ? error.message : "The read failed.";
        worsen({ kind: "failed", message });
        return degraded<PendingOpRecord[]>("failed", message);
      }
    },

    putPendingOp: (record) => write(PENDING_OPS, (store) => store.put(record), undefined),

    deletePendingOp: (key) => write(PENDING_OPS, (store) => store.delete(key), undefined),

    async deletePendingOps(initiativeId) {
      const listed = await storage.listPendingOps();
      if (!listed.ok) return listed;
      for (const record of listed.value) {
        if (record.initiativeId !== initiativeId) continue;
        const deleted = await storage.deletePendingOp(record.key);
        if (!deleted.ok) return deleted;
      }
      return ok(undefined);
    },

    async enforceBounds(keep = null) {
      try {
        const held = await snapshots();
        return ok(await bounded(held.live, keep));
      } catch (error) {
        const message = error instanceof Error ? error.message : "The cleanup failed.";
        worsen({ kind: "failed", message });
        return degraded<number[]>("failed", message);
      }
    },

    close() {
      closed = true;
      db.close();
    },
  };

  return storage;
}

// ---------------------------------------------------------------------------
// The fallback
// ---------------------------------------------------------------------------

/**
 * The same interface over a Map. It is not a pretend IndexedDB: its status says
 * `unavailable` when it stands in for a store that would not open, so the UI can
 * tell the user this tab has no durable recovery.
 */
export function createMemoryStorage(
  userId: number,
  status: StorageStatus = "unavailable",
  clock: () => number = () => Date.now(),
  limits: BoundLimits = DEFAULT_LIMITS,
): AccountStorage {
  const snapshots = new Map<number, SnapshotRecord>();
  const meta = new Map<string, unknown>();
  const pending = new Map<string, PendingOpRecord>();

  const storage: AccountStorage = {
    kind: "memory",
    userId,
    status: () => status,

    async putSnapshot(input) {
      const record: SnapshotRecord = {
        initiativeId: input.initiativeId,
        seq: input.seq,
        savedAt: input.savedAt ?? clock(),
        bytes: payloadBytes(input.payload),
        payload: input.payload,
      };
      snapshots.set(record.initiativeId, record);
      await storage.enforceBounds(record.initiativeId);
      return ok(record);
    },

    getSnapshot: (initiativeId) =>
      Promise.resolve(ok(snapshots.get(initiativeId) ?? null)),

    listSnapshots: () => Promise.resolve(ok([...snapshots.values()])),

    deleteSnapshot(initiativeId) {
      snapshots.delete(initiativeId);
      return Promise.resolve(ok(undefined));
    },

    getMeta: (key) => Promise.resolve(ok(meta.get(key) ?? null)),

    putMeta(key, value) {
      meta.set(key, value);
      return Promise.resolve(ok(undefined));
    },

    listPendingOps: () => Promise.resolve(ok([...pending.values()])),

    putPendingOp(record) {
      pending.set(record.key, record);
      return Promise.resolve(ok(undefined));
    },

    deletePendingOp(key) {
      pending.delete(key);
      return Promise.resolve(ok(undefined));
    },

    deletePendingOps(initiativeId) {
      for (const [key, record] of pending) if (record.initiativeId === initiativeId) pending.delete(key);
      return Promise.resolve(ok(undefined));
    },

    enforceBounds(keep = null) {
      const plan = evictionPlan([...snapshots.values()], clock(), limits, keep);
      for (const id of plan) snapshots.delete(id);
      return Promise.resolve(ok(plan));
    },

    close() {
      snapshots.clear();
      meta.clear();
      pending.clear();
    },
  };

  return storage;
}

// ---------------------------------------------------------------------------
// Purging
// ---------------------------------------------------------------------------

/**
 * Deletes this account's databases at EVERY schema version we have ever used,
 * not just the current one: on a browser without `databases()` the boot sweep
 * cannot see an older one, so sign-out is the only chance to remove it.
 */
export async function purgeAccountDbs(
  userId: number,
  idb: IdbFactoryLike | null,
): Promise<boolean> {
  let deleted = false;
  for (let schema = SCHEMA_VERSION; schema >= 1; schema -= 1) {
    if (await purgeAccountDb(userId, idb, schema)) deleted = true;
  }
  return deleted;
}

/** Deletes this account's database. Resolves either way — logout never waits on us. */
export async function purgeAccountDb(
  userId: number,
  idb: IdbFactoryLike | null,
  schema: number = SCHEMA_VERSION,
): Promise<boolean> {
  if (idb === null) return false;
  try {
    await request(idb.deleteDatabase(accountDbName(userId, schema)));
    return true;
  } catch {
    return false;
  }
}

/**
 * Deletes every `doit:` database that is not this account's current one —
 * another account sharing the profile, or this account under an older schema.
 * `databases()` is missing in some browsers; there is nothing honest to do
 * about that here, so it returns what it managed.
 */
export async function purgeOtherAccountDbs(
  userId: number,
  idb: IdbFactoryLike | null,
): Promise<string[]> {
  if (idb === null || typeof idb.databases !== "function") return [];

  let names: string[];
  try {
    names = (await idb.databases()).map((entry) => entry.name ?? "").filter((name) => name !== "");
  } catch {
    return [];
  }

  const mine = accountDbName(userId);
  const deleted: string[] = [];
  for (const name of names) {
    if (name === mine) continue;
    if (parseDbName(name) === null) continue;
    try {
      await request(idb.deleteDatabase(name));
      deleted.push(name);
    } catch {
      // A database another tab is holding open will be swept next boot.
    }
  }
  return deleted;
}

export type { BoundLimits, BoundedRecord };
