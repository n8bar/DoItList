// The live connection seam (m04.01 item 3.7).
//
// Task 8 puts a socket behind this. What matters *now* is where it lives: the
// connection is created once at boot and held outside React, so a route change
// — which unmounts one screen and mounts another — cannot tear it down and
// stand it back up. Guardrail §7.4: navigating keeps the live session,
// subscriptions and presence; a user who walks between Initiatives should not
// disappear from everyone else's presence list and reappear.
//
// Everything below is a stub with real bookkeeping: the subscription set is
// tracked for real (so leaks show up in tests today), the transport is not.

import type { ConnectionStatus } from "../state/recovery.ts";

export interface Connection {
  /** Stable for the life of the tab; a new value means something recreated it. */
  readonly id: string;
  status(): ConnectionStatus;
  /** Stub until Task 8. Subscribing twice to the same Initiative is a no-op. */
  subscribeInitiative(id: number): void;
  /** Stub until Task 8. Unsubscribing something not subscribed is a no-op. */
  unsubscribeInitiative(id: number): void;
  /** Currently subscribed Initiative ids, in subscribe order. */
  subscriptions(): readonly number[];
  /** Drops the live session and everything subscribed on it. Task 8 owns when. */
  disconnect(): void;
  /**
   * How many times this connection has been established. It must still read 1
   * after any amount of navigating — a second connect means the live session,
   * and the user's presence with it, was dropped and rebuilt.
   */
  connectCount(): number;
}

let nextConnectionId = 0;

export function createConnection(): Connection {
  nextConnectionId += 1;
  const id = `conn-${nextConnectionId}`;
  const subscriptions = new Set<number>();
  let connected = false;
  let connects = 0;

  // Task 8 replaces this with the socket handshake. What it is here for now is
  // the count: connecting is something that happens, so a regression that
  // rebuilds the connection on every route change is visible rather than
  // vacuously "still 1".
  const connect = () => {
    if (connected) return;
    connected = true;
    connects += 1;
  };

  connect();

  return {
    id,
    // Task 8 reports the real transport state; until then the client behaves as
    // if reads are live, which is what the HTTP surface actually is.
    status: (): ConnectionStatus => (connected ? "online" : "offline"),
    subscribeInitiative(initiativeId) {
      connect();
      subscriptions.add(initiativeId);
    },
    unsubscribeInitiative(initiativeId) {
      subscriptions.delete(initiativeId);
    },
    subscriptions: () => [...subscriptions],
    disconnect() {
      connected = false;
      subscriptions.clear();
    },
    connectCount: () => connects,
  };
}

let instance: Connection | null = null;

/**
 * The one connection for this tab. Called from boot and from any view that
 * needs to subscribe; every caller gets the same object.
 */
export function getConnection(): Connection {
  if (instance === null) instance = createConnection();
  return instance;
}

/** Test-only: forgets the singleton so a suite can start from a clean tab. */
export function resetConnection(): void {
  instance = null;
}
