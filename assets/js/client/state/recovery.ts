// Recovery state: how the client stands with the server (m04.01 item 3.1).
//
// Fields only in this arc. Arc 3 (live sync and recovery) fills in the queue
// behaviour, the replay and the snapshot writing; declaring the shape now keeps
// the seam honest — nothing else in the client gets to invent its own private
// "are we online?" flag, and nothing else gets to stash a pending write in a
// component.

import type { Store } from "./store.ts";
import { createStore } from "./store.ts";

/**
 * Where the live connection stands. `connecting` is the boot state; `offline`
 * means the client is serving what it already has and queueing what the user
 * does; `reconnecting` is a retry in flight after an `offline`.
 */
export type ConnectionStatus = "connecting" | "online" | "reconnecting" | "offline";

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

export interface RecoveryState {
  readonly connection: ConnectionStatus;
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
}

export const initialRecoveryState: RecoveryState = {
  connection: "connecting",
  pendingWrites: [],
  snapshotInitiativeId: null,
  snapshotVersion: null,
  snapshotAt: null,
  lastSyncedAt: null,
};

export type RecoveryStore = Store<RecoveryState>;

export function createRecoveryStore(initial: Partial<RecoveryState> = {}): RecoveryStore {
  return createStore<RecoveryState>({ ...initialRecoveryState, ...initial });
}

export function setConnectionStatus(store: RecoveryStore, connection: ConnectionStatus): void {
  store.set((state) => (state.connection === connection ? state : { ...state, connection }));
}
