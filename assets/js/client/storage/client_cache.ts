// The tab's one handle on its account cache (m04.01 items 3.4–3.6; m04.03 2.1, 2.4).
//
// Opening a database is asynchronous; screens are not. This wraps the open in a
// promise every caller shares, so a snapshot written a few milliseconds into the
// boot is not silently dropped and a read issued at mount still gets an answer.
// Nothing here can reject: the UI's only view of storage trouble is a status and
// a sentence, never an exception in a render (spec §5).
//
// Queued operations go through here too. The handle keeps a mirror of what it
// has written and not yet deleted — seeded from the store when it opens — and
// tells its listener after every change, so the count the user is shown (and
// warned about before Sign out) is what the device holds, not a guess.

import type { AccountCache, AccountCacheDeps } from "./account.ts";
import { openAccountCache, purgeAccountCache } from "./account.ts";
import type { AccountStorage, PendingOpRecord, StorageDegraded, StorageStatus } from "./db.ts";
import { createMemoryStorage } from "./db.ts";
import type { IdbFactoryLike } from "./idb.ts";
import type { KeyValueStore } from "./last_user.ts";
import type { PendingOp } from "./pending_ops.ts";
import { byCreation, parsePendingOp } from "./pending_ops.ts";
import type { SnapshotMeta, TreeCache } from "./snapshots.ts";
import { createTreeCache } from "./snapshots.ts";

export interface ClientCacheDeps {
  /** `null` for a signed-out tab: nothing is opened and nothing is written. */
  readonly userId: number | null;
  readonly idb: IdbFactoryLike | null;
  readonly keyValue: KeyValueStore | null;
  readonly now?: () => number;
  readonly onStatus?: (status: StorageStatus, reason: StorageDegraded | null) => void;
  readonly onMeta?: (meta: SnapshotMeta | null) => void;
  /** Told what is queued whenever it changes, oldest first — and once on open. */
  readonly onPending?: (records: readonly PendingOp[]) => void;
}

export interface ClientCache extends TreeCache {
  /**
   * Access to this Initiative is gone: its snapshot and its queued operations
   * go, and a write still in flight for it is discarded on arrival rather than
   * left on disk.
   */
  forgetInitiative(initiativeId: number): Promise<void>;
  /** Resolves when the account store is open (or has failed over to memory). */
  readonly ready: Promise<AccountCache>;
  /** The account this cache belongs to. */
  userId(): number | null;
  /**
   * The signed-in user turned out to be somebody else (a re-login in another
   * tab, say): the old account's cache goes and this one opens.
   */
  switchTo(userId: number): Promise<void>;
  /**
   * Journals one queued operation (or rewrites it under the same key). Resolves
   * with whether it landed; a refused write is `false`, never a rejection —
   * the send goes either way.
   */
  putPendingOp(record: PendingOpRecord): Promise<boolean>;
  /** The outcome is known: the record goes. Never rejects. */
  deletePendingOp(key: string): Promise<void>;
  /**
   * The operations this device has queued and not yet settled, oldest first.
   * Empty when the store is unavailable or refused the read: a cache that
   * cannot answer is not a reason to claim there is unsent work.
   */
  pendingOps(): Promise<readonly PendingOp[]>;
  /** Sign-out: everything this account left on the device, gone. */
  purge(): Promise<boolean>;
  close(): void;
}

const inertCache = (deps: ClientCacheDeps): AccountCache => ({
  storage: createMemoryStorage(0, "unavailable", deps.now ?? (() => Date.now())),
  purged: [],
  lastSnapshot: null,
});

export function openClientCache(deps: ClientCacheDeps): ClientCache {
  const onMeta = deps.onMeta ?? (() => {});
  const onPending = deps.onPending ?? (() => {});
  let userId = deps.userId;
  /**
   * One counter per Initiative, bumped by `forgetInitiative`. A write captures
   * it before it starts and checks it after: a snapshot that landed after the
   * forget is deleted again, so losing access cannot be beaten by a read that
   * was already on its way.
   */
  const forgotten = new Map<number, number>();
  const generation = (id: number): number => forgotten.get(id) ?? 0;

  /** What this handle knows is queued, by key. Seeded from the store on open. */
  let pending = new Map<string, PendingOp>();
  const announce = (): void => onPending([...pending.values()].sort(byCreation));

  /**
   * Reads the store's queue into the mirror, deleting rows that do not read
   * back. Anything queued while the store was still opening is kept: its
   * write is waiting on this very open and lands right after.
   */
  const seedPending = async (storage: AccountStorage): Promise<void> => {
    const listed = await storage.listPendingOps();
    const next = new Map<string, PendingOp>();
    if (listed.ok) {
      for (const row of listed.value) {
        const parsed = parsePendingOp(row);
        if (parsed !== null) next.set(parsed.key, parsed);
        else await storage.deletePendingOp(row.key);
      }
    }
    for (const [key, record] of pending) next.set(key, record);
    pending = next;
    announce();
  };

  const open = (id: number): Promise<AccountCache> => {
    const options: AccountCacheDeps = {
      userId: id,
      idb: deps.idb,
      keyValue: deps.keyValue,
      ...(deps.now === undefined ? {} : { now: deps.now }),
      ...(deps.onStatus === undefined ? {} : { onStatus: deps.onStatus }),
    };
    return openAccountCache(options).then(async (cache) => {
      deps.onStatus?.(cache.storage.status(), null);
      onMeta(cache.lastSnapshot);
      await seedPending(cache.storage);
      return cache;
    });
  };

  let ready: Promise<AccountCache> =
    userId === null ? Promise.resolve(inertCache(deps)) : open(userId);

  const storage = (): Promise<AccountStorage> => ready.then((cache) => cache.storage);
  // One tree cache per open store, not one per write.
  let trees: Promise<TreeCache> | null = null;
  const tree = (): Promise<TreeCache> => {
    trees ??= storage().then((account) =>
      createTreeCache({
        storage: account,
        onMeta,
        onMetaCleared: () => onMeta(null),
      }),
    );
    return trees;
  };

  const cache: ClientCache = {
    get ready() {
      return ready;
    },

    userId: () => userId,

    cacheTree(value) {
      void cache.writeTree(value);
    },

    async writeTree(value) {
      if (userId === null) return false;
      const gen = generation(value.initiativeId);
      const store = await tree();
      const written = await store.writeTree(value);
      // Access was taken away while this write was in flight: undo it.
      if (generation(value.initiativeId) !== gen) {
        await store.forgetTree(value.initiativeId);
        return false;
      }
      return written;
    },

    async forgetInitiative(initiativeId) {
      forgotten.set(initiativeId, generation(initiativeId) + 1);
      if (userId === null) return;
      // Nothing queued for an Initiative the user lost is ever replayed
      // (item 2.4.2): the records go with the snapshot.
      for (const [key, record] of pending) if (record.initiativeId === initiativeId) pending.delete(key);
      announce();
      const [store, account] = await Promise.all([tree(), storage()]);
      await Promise.all([store.forgetTree(initiativeId), account.deletePendingOps(initiativeId)]);
    },

    /** Same thing under the `TreeCache` name; the sequencing is not optional. */
    forgetTree: (initiativeId) => cache.forgetInitiative(initiativeId),

    async readTree(initiativeId) {
      if (userId === null) return null;
      return (await tree()).readTree(initiativeId);
    },

    async switchTo(nextUserId) {
      if (nextUserId === userId) return;
      trees = null;
      const previous = userId;
      const opened = await ready;
      opened.storage.close();
      if (previous !== null) {
        await purgeAccountCache({
          userId: previous,
          idb: deps.idb,
          keyValue: deps.keyValue,
          storage: null,
        });
      }
      userId = nextUserId;
      ready = open(nextUserId);
      await ready;
    },

    async putPendingOp(record) {
      if (userId === null) return false;
      const parsed = parsePendingOp(record);
      if (parsed === null) return false;
      const gen = generation(record.initiativeId);
      pending.set(record.key, parsed);
      announce();
      try {
        const account = await storage();
        const written = await account.putPendingOp(record);
        // Access went while the write was on its way: it must not stay.
        if (generation(record.initiativeId) !== gen) {
          await account.deletePendingOp(record.key);
          return false;
        }
        return written.ok;
      } catch {
        return false;
      }
    },

    async deletePendingOp(key) {
      if (userId === null) return;
      if (pending.delete(key)) announce();
      try {
        await (await storage()).deletePendingOp(key);
      } catch {
        // A row that will not delete is swept with the database on sign-out;
        // the mirror already says it is gone, so it is not replayed.
      }
    },

    async pendingOps() {
      if (userId === null) return [];
      await ready;
      return [...pending.values()].sort(byCreation);
    },

    async purge() {
      if (userId === null) return false;
      // Nothing about signing out may reject: the caller submits the request
      // that ends the session either way (spec §12, UX_GUARDRAILS §6.7).
      try {
        const opened = await ready;
        trees = null;
        pending = new Map();
        announce();
        return await purgeAccountCache({
          userId,
          idb: deps.idb,
          keyValue: deps.keyValue,
          storage: opened.storage,
        });
      } catch {
        return false;
      }
    },

    close() {
      void ready.then((opened) => opened.storage.close());
    },
  };

  return cache;
}
