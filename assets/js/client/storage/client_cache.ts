// The tab's one handle on its account cache (m04.01 items 3.4–3.6).
//
// Opening a database is asynchronous; screens are not. This wraps the open in a
// promise every caller shares, so a snapshot written a few milliseconds into the
// boot is not silently dropped and a read issued at mount still gets an answer.
// Nothing here can reject: the UI's only view of storage trouble is a status and
// a sentence, never an exception in a render (spec §5).

import type { AccountCache, AccountCacheDeps } from "./account.ts";
import { openAccountCache, purgeAccountCache } from "./account.ts";
import type { AccountStorage, StorageDegraded, StorageStatus } from "./db.ts";
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
  /** Resolves when the account store is open (or has failed over to memory). */
  readonly ready: Promise<AccountCache>;
  /** The account this cache belongs to. */
  userId(): number | null;
  /**
   * The signed-in user turned out to be somebody else (a re-login in another
   * tab, say): the old account's cache goes and this one opens.
   */
  switchTo(userId: number): Promise<void>;
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
  const tree = (): Promise<TreeCache> =>
    storage().then((account) => createTreeCache({ storage: account, onMeta }));

  return {
    get ready() {
      return ready;
    },

    userId: () => userId,

    cacheTree(value) {
      if (userId === null) return;
      void tree().then((cache) => cache.cacheTree(value));
    },

    async readTree(initiativeId) {
      if (userId === null) return null;
      return (await tree()).readTree(initiativeId);
    },

    async switchTo(nextUserId) {
      if (nextUserId === userId) return;
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
      const opened = await ready;
      return purgeAccountCache({
        userId,
        idb: deps.idb,
        keyValue: deps.keyValue,
        storage: opened.storage,
      });
    },

    close() {
      void ready.then((cache) => cache.storage.close());
    },
  };
}
