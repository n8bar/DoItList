// Recovery state: how the client stands with the server (m04.01 item 3.1).
//
// Fields only in this arc. Arc 3 (live sync and recovery) fills in the queue
// behaviour, the replay and the snapshot writing; declaring the shape now keeps
// the seam honest — nothing else in the client gets to invent its own private
// "are we online?" flag, and nothing else gets to stash a pending write in a
// component.

import type { StorageStatus } from "../storage/db.ts";
import type { SnapshotMeta } from "../storage/snapshots.ts";
import type { Store } from "./store.ts";
import { createStore } from "./store.ts";

/**
 * Where the live connection stands. `connecting` is the boot state; `live`
 * means the socket is open and the joined Initiative is being kept current;
 * `reconnecting` is a retry in flight; `offline` means the client has stopped
 * retrying, is serving what it already has, and is waiting for the user to ask
 * it to try again (`Connection.retry()`).
 */
export type ConnectionStatus = "connecting" | "live" | "reconnecting" | "offline";

/**
 * A write the user has made that the server has not yet acknowledged. Arc 3
 * owns the queue; this is the record it will queue.
 */
export interface PendingWrite {
  readonly id: string;
  /** The `POST /app/api/operations` op, opaque here. */
  readonly operation: unknown;
  /** Milliseconds since the epoch, when the user made the change. */
  readonly queuedAt: number;
}

/**
 * How the local recovery cache stands. `opening` is the boot state; `ready`
 * means writes land; `degraded` means the store is there but has refused
 * something; `unavailable` means this tab has no durable recovery at all and
 * the user is entitled to be told so.
 */
export type StorageHealth = "opening" | StorageStatus;

export interface RecoveryState {
  readonly connection: ConnectionStatus;
  /** The local cache's health. */
  readonly storage: StorageHealth;
  /** One plain sentence about why, when the health is not `ready`. */
  readonly storageNote: string | null;
  /** Writes made but not yet acknowledged. Arc 3 drains this; nothing does yet. */
  readonly pendingWrites: readonly PendingWrite[];
  /** The Initiative the last local snapshot covers, or `null`. */
  readonly snapshotInitiativeId: number | null;
  /** That snapshot's Initiative `version`, or `null`. */
  readonly snapshotVersion: number | null;
  /** When the snapshot was written (ms since the epoch), or `null`. */
  readonly snapshotAt: number | null;
  /** The last moment the server confirmed we were current (ms since the epoch). */
  readonly lastSyncedAt: number | null;
  /**
   * An unrecoverable client-side failure the user must reload out of, in one
   * plain sentence, or `null` (spec §7). It is deliberately NOT a takeover:
   * the tree on screen is still readable, so the client says what happened and
   * offers the way out rather than replacing the page.
   */
  readonly fatalError: string | null;
}

export const initialRecoveryState: RecoveryState = {
  connection: "connecting",
  storage: "opening",
  storageNote: null,
  pendingWrites: [],
  snapshotInitiativeId: null,
  snapshotVersion: null,
  snapshotAt: null,
  lastSyncedAt: null,
  fatalError: null,
};

export type RecoveryStore = Store<RecoveryState>;

export function createRecoveryStore(initial: Partial<RecoveryState> = {}): RecoveryStore {
  return createStore<RecoveryState>({ ...initialRecoveryState, ...initial });
}

export function setConnectionStatus(store: RecoveryStore, connection: ConnectionStatus): void {
  store.set((state) => (state.connection === connection ? state : { ...state, connection }));
}

export function setStorageHealth(
  store: RecoveryStore,
  storage: StorageHealth,
  storageNote: string | null = null,
): void {
  store.set((state) =>
    state.storage === storage && state.storageNote === storageNote
      ? state
      : { ...state, storage, storageNote },
  );
}

/**
 * Records an unrecoverable client failure. The FIRST one wins: what broke first
 * is the useful thing to say, and everything after it is likely fallout.
 */
export function setFatalError(store: RecoveryStore, message: string): void {
  store.set((state) => (state.fatalError === null ? { ...state, fatalError: message } : state));
}

/** Records the newest snapshot this device holds, or that it holds none. */
export function setSnapshotMeta(store: RecoveryStore, meta: SnapshotMeta | null): void {
  store.set((state) => ({
    ...state,
    snapshotInitiativeId: meta?.initiativeId ?? null,
    snapshotVersion: meta?.version ?? null,
    snapshotAt: meta?.savedAt ?? null,
  }));
}
