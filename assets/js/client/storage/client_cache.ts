// The tab's one handle on its account cache (m04.01 items 3.4–3.6).
//
// Opening a database is asynchronous; screens are not. This wraps the open in a
// promise every caller shares, so a snapshot written a few milliseconds into the
// boot is not silently dropped and a read issued at mount still gets an answer.
// Nothing here can reject: the UI's only view of storage trouble is a status and
// a sentence, never an exception in a render (spec §5).

import type { AccountCache, AccountCacheDeps } from "./account.ts";
import { openAccountCache, purgeAccountCache } from "./account.ts";
import type {
  AccountStorage,
  PendingOpRecord,
  StorageDegraded,
  StorageStatus,
} from "./db.ts";
import { createMemoryStorage } from "./db.ts";
import type { IdbFactoryLike } from "./idb.ts";
import type { KeyValueStore } from "./last_user.ts";
import type { InitiativeSnapshot, SnapshotMeta, TreeCache } from "./snapshots.ts";
import { createTreeCache } from "./snapshots.ts";

export interface ClientCacheDeps {
  /** `null` for a signed-out tab: nothing is opened and nothing is written. */
  readonly userId: number | null;
  readonly idb: IdbFactoryLike | null;
  readonly keyValue: KeyValueStore | null;
  readonly now?: () => number;
  readonly onStatus?: (status: StorageStatus, reason: StorageDegraded | null) => void;
  readonly onMeta?: (meta: SnapshotMeta | null) => void;
}

export interface ClientCache extends TreeCache {
  /**
   * Access to this Initiative is gone: its snapshot goes, and a write still in
   * flight for it is discarded on arrival rather than left on disk.
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
   * The ops this device queued and has not sent. Empty when the store is
   * unavailable or refused the read: a cache that cannot answer is not a
   * reason to claim there is unsent work.
   */
  pendingOps(): Promise<readonly PendingOpRecord[]>;
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
  let userId = deps.userId;
  /**
   * One counter per Initiative, bumped by `forgetInitiative`. A write captures
   * it before it starts and checks it after: a snapshot that landed after the
   * forget is deleted again, so losing access cannot be beaten by a read that
   * was already on its way.
   */
  const forgotten = new Map<number, number>();
  const generation = (id: number): number => forgotten.get(id) ?? 0;

  const open = (id: number): Promise<AccountCache> => {
    const options: AccountCacheDeps = {
      userId: id,
      idb: deps.idb,
      keyValue: deps.keyValue,
      ...(deps.now === undefined ? {} : { now: deps.now }),
      ...(deps.onStatus === undefined ? {} : { onStatus: deps.onStatus }),
    };
    return openAccountCache(options).then((cache) => {
      deps.onStatus?.(cache.storage.status(), null);
      onMeta(cache.lastSnapshot);
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
      await (await tree()).forgetTree(initiativeId);
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

    async purge() {
      if (userId === null) return false;
      // Nothing about signing out may reject: the caller submits the request
      // that ends the session either way (spec §12, UX_GUARDRAILS §6.7).
      try {
        const opened = await ready;
        trees = null;
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

    async pendingOps() {
      if (userId === null) return [];
      const opened = await ready;
      const result = await opened.storage.listPendingOps();
      return result.ok ? result.value : [];
    },

    close() {
      void ready.then((opened) => opened.storage.close());
    },
  };

  return cache;
}
