import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  JITTER_RATIO,
  MAX_RECONNECT_DELAY_MS,
  RECONNECT_BUDGET,
  RECONNECT_DELAYS_MS,
  budgetSpent,
  initialLinkState,
  nextLinkState,
  reconnectDelayMs,
} from "./connection_state.ts";
import type { LinkEvent, LinkState } from "./connection_state.ts";

const run = (events: LinkEvent[], from: LinkState = initialLinkState): LinkState =>
  events.reduce(nextLinkState, from);

/**
 * What ONE failed connect attempt really looks like: Phoenix fires `onerror`,
 * schedules the retry, then fires `onclose`. Counting the callbacks instead of
 * the schedule is what burns the budget twice as fast as it reads.
 */
const attempts = (count: number, from = 0): LinkEvent[] =>
  Array.from({ length: count }, (_, i) => [
    { kind: "drop" } as LinkEvent,
    { kind: "attempt", tries: from + i + 1 } as LinkEvent,
    { kind: "drop" } as LinkEvent,
  ]).flat();

describe("the live connection's state machine (item 1.5)", () => {
  it("starts out connecting", () => {
    assert.equal(initialLinkState.status, "connecting");
    assert.equal(initialLinkState.attempts, 0);
    assert.equal(initialLinkState.exhausted, false);
  });

  it("goes live when the socket opens", () => {
    assert.equal(run([{ kind: "open" }]).status, "live");
  });

  it("reports the same state object when nothing changed", () => {
    const live = run([{ kind: "open" }]);
    assert.equal(nextLinkState(live, { kind: "open" }), live);
  });

  it("shows reconnecting while it is still trying", () => {
    const state = run([{ kind: "open" }, ...attempts(1)]);
    assert.equal(state.status, "reconnecting");
    assert.equal(state.attempts, 1);
    assert.equal(state.exhausted, false);
  });

  it("shows reconnecting the moment the socket drops, before a retry is scheduled", () => {
    const state = run([{ kind: "open" }, { kind: "drop" }]);
    assert.equal(state.status, "reconnecting");
    assert.equal(state.attempts, 0, "a drop must not count as an attempt");
  });

  it("counts a failure before the socket ever opened", () => {
    assert.equal(run(attempts(1)).status, "reconnecting");
  });

  it("does NOT spend two attempts on one failed connect", () => {
    // The whole finding: one attempt fires both `onerror` and `onclose`.
    const state = run(attempts(RECONNECT_BUDGET));
    assert.equal(state.attempts, RECONNECT_BUDGET);
    assert.equal(state.status, "reconnecting", "the budget was spent twice as fast as it reads");
  });

  it("gives up once the schedule runs past the budget", () => {
    const state = run(attempts(RECONNECT_BUDGET + 1));
    assert.equal(state.status, "offline");
    assert.equal(state.exhausted, true);

    const still = run(attempts(3, RECONNECT_BUDGET + 1), state);
    assert.equal(still, state, "a spent budget must not keep counting");
  });

  it("does not give up one attempt early", () => {
    assert.equal(run(attempts(RECONNECT_BUDGET)).status, "reconnecting");
  });

  it("a successful open clears the budget", () => {
    const recovered = run([...attempts(RECONNECT_BUDGET), { kind: "open" }, ...attempts(1)]);
    assert.equal(recovered.status, "reconnecting");
    assert.equal(recovered.attempts, 1);
  });

  it("retry starts over from connecting", () => {
    const state = run([...attempts(RECONNECT_BUDGET + 1), { kind: "retry" }]);
    assert.deepEqual(state, initialLinkState);
  });

  it("hanging up deliberately is offline, not reconnecting", () => {
    const state = run([{ kind: "open" }, { kind: "down" }]);
    assert.equal(state.status, "offline");
    assert.equal(state.exhausted, true);
  });

  describe("the backoff schedule", () => {
    // Jitter is injected, so every bound below is asserted, never sampled.
    const mid = () => 0.5;
    const low = () => 0;
    const high = () => 1 - Number.EPSILON;

    it("starts fast and grows", () => {
      assert.ok(reconnectDelayMs(1, mid) < reconnectDelayMs(5, mid));
      assert.ok(reconnectDelayMs(5, mid) < reconnectDelayMs(RECONNECT_BUDGET, mid));
    });

    it("is the scheduled delay when the jitter lands in the middle", () => {
      assert.equal(reconnectDelayMs(4, mid), RECONNECT_DELAYS_MS[3]);
    });

    it("jitters both ways, within the ratio", () => {
      const base = RECONNECT_DELAYS_MS[7] ?? 0;
      assert.equal(reconnectDelayMs(8, low), Math.round(base * (1 - JITTER_RATIO)));
      assert.equal(reconnectDelayMs(8, high), Math.round(base * (1 + JITTER_RATIO)));
      assert.notEqual(reconnectDelayMs(8, low), reconnectDelayMs(8, high));
    });

    it("stays inside the bounds for every attempt and every draw", () => {
      for (let tries = 1; tries <= RECONNECT_BUDGET + 5; tries += 1) {
        for (const random of [low, mid, high]) {
          const delay = reconnectDelayMs(tries, random);
          const base = RECONNECT_DELAYS_MS[Math.min(tries, RECONNECT_DELAYS_MS.length) - 1] ?? 0;
          assert.ok(delay >= Math.round(base * (1 - JITTER_RATIO)), `too small at ${tries}`);
          assert.ok(delay <= MAX_RECONNECT_DELAY_MS, `past the ceiling at ${tries}`);
          assert.ok(delay >= 1);
        }
      }
    });

    it("is bounded past the end of the schedule", () => {
      assert.equal(reconnectDelayMs(50, mid), reconnectDelayMs(RECONNECT_BUDGET, mid));
    });

    it("never returns a nonsense delay", () => {
      for (const tries of [0, -3, 1.5]) {
        assert.ok(Number.isFinite(reconnectDelayMs(tries, mid)) && reconnectDelayMs(tries, mid) > 0);
      }
    });

    it("knows when the budget is spent", () => {
      assert.equal(budgetSpent(RECONNECT_BUDGET), false);
      assert.equal(budgetSpent(RECONNECT_BUDGET + 1), true);
    });
  });
});
