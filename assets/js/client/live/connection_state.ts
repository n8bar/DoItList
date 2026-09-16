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
//
// **Attempts are counted from the retry schedule, not from socket callbacks.**
// One failed WebSocket attempt fires `onerror` AND `onclose` (phoenix.mjs
// `onConnError` then `onConnClose`), so counting callbacks would spend a
// ten-attempt budget in five attempts — and the whole first half-second of the
// backoff table. Phoenix calls `reconnectAfterMs(tries)` exactly once per
// scheduled attempt, and `tries` is what the `attempt` event carries.

import type { ConnectionStatus } from "../state/recovery.ts";

/** Attempts Phoenix may schedule before the client stops retrying by itself. */
export const RECONNECT_BUDGET = 10;

/** Bounded exponential backoff, in milliseconds, indexed by attempt (1-based). */
export const RECONNECT_DELAYS_MS: readonly number[] = [
  10, 50, 100, 150, 200, 250, 500, 1000, 2000, 5000,
];

/** The ceiling the jitter may never push a delay past (spec §5: bounded). */
export const MAX_RECONNECT_DELAY_MS = 5_000;

/** How far either side of the scheduled delay the jitter may land. */
export const JITTER_RATIO = 0.25;

export interface LinkState {
  readonly status: ConnectionStatus;
  /** Scheduled reconnect attempts since the last open. */
  readonly attempts: number;
  /** The budget is spent: nothing is scheduled, only `retry` moves us. */
  readonly exhausted: boolean;
}

export type LinkEvent =
  /** The socket opened. */
  | { kind: "open" }
  /**
   * The socket closed or errored. Says only "we are not live"; it does NOT
   * count, because one failed attempt fires this twice.
   */
  | { kind: "drop" }
  /** Phoenix scheduled reconnect attempt number `tries` (1-based). */
  | { kind: "attempt"; tries: number }
  /** The user asked to try again. */
  | { kind: "retry" }
  /** We deliberately hung up (sign-out, tab teardown). */
  | { kind: "down" };

export const initialLinkState: LinkState = {
  status: "connecting",
  attempts: 0,
  exhausted: false,
};

/**
 * The delay before attempt `tries` (1-based): the schedule above, jittered by
 * ±`JITTER_RATIO` so a server coming back does not take every client's
 * reconnect in the same millisecond (spec §5). `random` returns [0, 1) and is
 * injected so the bounds can be asserted rather than sampled. The result never
 * exceeds `MAX_RECONNECT_DELAY_MS` — jitter spreads a delay, it never extends
 * the ceiling.
 */
export function reconnectDelayMs(tries: number, random: () => number = Math.random): number {
  const index = Math.max(1, Math.trunc(tries)) - 1;
  const last = RECONNECT_DELAYS_MS[RECONNECT_DELAYS_MS.length - 1] ?? MAX_RECONNECT_DELAY_MS;
  const base = RECONNECT_DELAYS_MS[Math.min(index, RECONNECT_DELAYS_MS.length - 1)] ?? last;
  const spread = (random() * 2 - 1) * JITTER_RATIO;
  return Math.min(MAX_RECONNECT_DELAY_MS, Math.max(1, Math.round(base * (1 + spread))));
}

/** True once the schedule has run past the budget. */
export function budgetSpent(tries: number): boolean {
  return tries > RECONNECT_BUDGET;
}

export function nextLinkState(state: LinkState, event: LinkEvent): LinkState {
  switch (event.kind) {
    case "open":
      if (state.status === "live" && state.attempts === 0 && !state.exhausted) return state;
      return { status: "live", attempts: 0, exhausted: false };

    case "drop": {
      // Once we have stopped retrying, further close notices change nothing;
      // and a drop never moves the counter — `attempt` owns that.
      if (state.exhausted || state.status === "reconnecting") return state;
      return { ...state, status: "reconnecting" };
    }

    case "attempt": {
      if (state.exhausted) return state;
      const attempts = Math.max(1, Math.trunc(event.tries));
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
