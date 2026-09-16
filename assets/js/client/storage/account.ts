// Opening and closing an account's cache (m04.01 items 3.4, 3.6).
//
// One place decides the whole boot sequence, because the order matters: every
// other account's cache is gone BEFORE this account's is opened, and the marker
// that names the account is written only once that has happened. Anything else
// leaves a window in which a shared profile holds two accounts at once.

import type { AccountStorage, StorageDegraded, StorageStatus } from "./db.ts";
import { openAccountStorage, purgeAccountDb, purgeOtherAccountDbs } from "./db.ts";
import type { IdbFactoryLike } from "./idb.ts";
import type { KeyValueStore } from "./last_user.ts";
import { clearLastUser, readLastUser, staleAccount, writeLastUser } from "./last_user.ts";
import type { SnapshotMeta } from "./snapshots.ts";
import { LAST_SNAPSHOT_KEY, parseSnapshotMeta } from "./snapshots.ts";

export interface AccountCacheDeps {
  readonly userId: number;
  readonly idb: IdbFactoryLike | null;
  readonly keyValue: KeyValueStore | null;
  readonly now?: () => number;
  readonly onStatus?: (status: StorageStatus, reason: StorageDegraded | null) => void;
  readonly openTimeoutMs?: number;
}

export interface AccountCache {
  readonly storage: AccountStorage;
  /** User ids whose caches were thrown away on the way in. */
  readonly purged: number[];
  /** The newest snapshot this account has on this device, or `null`. */
  readonly lastSnapshot: SnapshotMeta | null;
}

/**
 * The cache this tab will use, with the profile already cleaned up:
 *
 *   1. a remembered OTHER user means their cache goes first;
 *   2. every `doit:` database that is not ours — another account, or an older
 *      schema of ours — is deleted;
 *   3. the marker now names us;
 *   4. the store opens (or fails over to memory, saying so);
 *   5. the bounds are applied to whatever the last session left behind;
 *   6. the newest snapshot's metadata comes back for the recovery store.
 */
export async function openAccountCache(deps: AccountCacheDeps): Promise<AccountCache> {
  const { userId, idb, keyValue } = deps;
  const purged: number[] = [];

  const stale = staleAccount(readLastUser(keyValue), userId);
  if (stale !== null && (await purgeAccountDb(stale, idb))) purged.push(stale);

  for (const name of await purgeOtherAccountDbs(userId, idb)) {
    const id = Number(name.split(":")[2]);
    if (Number.isInteger(id) && id !== userId && !purged.includes(id)) purged.push(id);
  }

  writeLastUser(keyValue, userId);

  const storage = await openAccountStorage({
    userId,
    idb,
    ...(deps.now === undefined ? {} : { now: deps.now }),
    ...(deps.onStatus === undefined ? {} : { onStatus: deps.onStatus }),
    ...(deps.openTimeoutMs === undefined ? {} : { openTimeoutMs: deps.openTimeoutMs }),
  });

  await storage.enforceBounds();
  const meta = await storage.getMeta(LAST_SNAPSHOT_KEY);

  return {
    storage,
    purged,
    lastSnapshot: meta.ok ? parseSnapshotMeta(meta.value) : null,
  };
}

/** How long sign-out will wait for the purge before it goes anyway. */
export const PURGE_TIMEOUT_MS = 1500;

/** Resolves with `fallback` if `work` has not finished in time. Never rejects. */
export function withTimeout<T>(work: Promise<T>, ms: number, fallback: T): Promise<T> {
  return new Promise<T>((resolve) => {
    const timer = setTimeout(() => resolve(fallback), ms);
    work.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      () => {
        clearTimeout(timer);
        resolve(fallback);
      },
    );
  });
}

/**
 * Everything this account left on the device, gone. Bounded: a store that will
 * not delete must not be able to trap the user in a session they asked to end,
 * so sign-out proceeds either way and the boot sweep tries again next time.
 */
export async function purgeAccountCache(deps: {
  userId: number;
  idb: IdbFactoryLike | null;
  keyValue: KeyValueStore | null;
  storage?: AccountStorage | null;
  timeoutMs?: number;
}): Promise<boolean> {
  deps.storage?.close();
  clearLastUser(deps.keyValue);
  return withTimeout(
    purgeAccountDb(deps.userId, deps.idb),
    deps.timeoutMs ?? PURGE_TIMEOUT_MS,
    false,
  );
}
