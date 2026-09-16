// The live connection's state machine (m04.01 item 1.5).
//
// Pure on purpose: "are we live, retrying, or have we given up?" is the one
// thing the user is told about the connection (spec §7), so it is decided here
// — in a module a unit test can drive through every transition — and not
// guessed at from whichever socket callback fired last.
//
// The budget is the whole point of the `offline` state. Phoenix retries
// forever by default, which reads to the user as a spinner that never resolves;
// after a bounded number of attempts the client stops, says so plainly, and
// offers a retry the user controls.

import type { ConnectionStatus } from "../state/recovery.ts";

/** Consecutive failed attempts before the client stops retrying by itself. */
export const RECONNECT_BUDGET = 10;

/** Phoenix-style backoff, in milliseconds, indexed by attempt (1-based). */
export const RECONNECT_DELAYS_MS: readonly number[] = [
  10, 50, 100, 150, 200, 250, 500, 1000, 2000, 5000,
];

export interface LinkState {
  readonly status: ConnectionStatus;
  /** Consecutive failed connect attempts since the last open. */
  readonly attempts: number;
  /** The budget is spent: nothing is scheduled, only `retry` moves us. */
  readonly exhausted: boolean;
}

export type LinkEvent =
  /** The socket opened. */
  | { kind: "open" }
  /** The socket closed or errored while we still want to be live. */
  | { kind: "drop" }
  /** The user asked to try again. */
  | { kind: "retry" }
  /** We deliberately hung up (sign-out, tab teardown). */
  | { kind: "down" };

export const initialLinkState: LinkState = {
  status: "connecting",
  attempts: 0,
  exhausted: false,
};

/** The delay before attempt `tries` (1-based), capped at the last step. */
export function reconnectDelayMs(tries: number): number {
  const index = Math.max(1, Math.trunc(tries)) - 1;
  const last = RECONNECT_DELAYS_MS[RECONNECT_DELAYS_MS.length - 1] ?? 5000;
  return RECONNECT_DELAYS_MS[Math.min(index, RECONNECT_DELAYS_MS.length - 1)] ?? last;
}

/** True once `tries` (1-based) has run past the budget. */
export function budgetSpent(tries: number): boolean {
  return tries >= RECONNECT_BUDGET;
}

export function nextLinkState(state: LinkState, event: LinkEvent): LinkState {
  switch (event.kind) {
    case "open":
      if (state.status === "live" && state.attempts === 0 && !state.exhausted) return state;
      return { status: "live", attempts: 0, exhausted: false };

    case "drop": {
      // Once we have stopped retrying, further close notices change nothing.
      if (state.exhausted) return state;
      const attempts = state.attempts + 1;
      return budgetSpent(attempts)
        ? { status: "offline", attempts, exhausted: true }
        : { status: "reconnecting", attempts, exhausted: false };
    }

    case "retry":
      return initialLinkState;

    case "down":
      if (state.status === "offline" && state.exhausted) return state;
      return { status: "offline", attempts: 0, exhausted: true };
  }
}
