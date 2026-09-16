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
  /** How many times `connect` has run. Must stay at 1 across route changes. */
  connectCount(): number;
}

let nextConnectionId = 0;

export function createConnection(): Connection {
  nextConnectionId += 1;
  const id = `conn-${nextConnectionId}`;
  const subscriptions = new Set<number>();
  // One "connect" per connection object. Task 8 replaces this with the socket
  // handshake; the count is what the continuity test asserts on.
  const connects = 1;

  return {
    id,
    // Task 8 reports the real transport state; until then the client behaves as
    // if reads are live, which is what the HTTP surface actually is.
    status: (): ConnectionStatus => "online",
    subscribeInitiative(initiativeId) {
      subscriptions.add(initiativeId);
    },
    unsubscribeInitiative(initiativeId) {
      subscriptions.delete(initiativeId);
    },
    subscriptions: () => [...subscriptions],
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
