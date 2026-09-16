import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  RECONNECT_BUDGET,
  budgetSpent,
  initialLinkState,
  nextLinkState,
  reconnectDelayMs,
} from "./connection_state.ts";
import type { LinkEvent, LinkState } from "./connection_state.ts";

const run = (events: LinkEvent[], from: LinkState = initialLinkState): LinkState =>
  events.reduce(nextLinkState, from);

const drops = (count: number): LinkEvent[] =>
  Array.from({ length: count }, () => ({ kind: "drop" }) as LinkEvent);

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
    const state = run([{ kind: "open" }, { kind: "drop" }]);
    assert.equal(state.status, "reconnecting");
    assert.equal(state.attempts, 1);
    assert.equal(state.exhausted, false);
  });

  it("counts a failure before the socket ever opened", () => {
    assert.equal(run([{ kind: "drop" }]).status, "reconnecting");
  });

  it("gives up after the budget and says so", () => {
    const state = run(drops(RECONNECT_BUDGET));
    assert.equal(state.status, "offline");
    assert.equal(state.exhausted, true);

    const still = run(drops(3), state);
    assert.equal(still, state, "a spent budget must not keep counting");
  });

  it("does not give up one attempt early", () => {
    assert.equal(run(drops(RECONNECT_BUDGET - 1)).status, "reconnecting");
  });

  it("a successful open clears the budget", () => {
    const recovered = run([...drops(RECONNECT_BUDGET - 1), { kind: "open" }, { kind: "drop" }]);
    assert.equal(recovered.status, "reconnecting");
    assert.equal(recovered.attempts, 1);
  });

  it("retry starts over from connecting", () => {
    const state = run([...drops(RECONNECT_BUDGET), { kind: "retry" }]);
    assert.deepEqual(state, initialLinkState);
  });

  it("hanging up deliberately is offline, not reconnecting", () => {
    const state = run([{ kind: "open" }, { kind: "down" }]);
    assert.equal(state.status, "offline");
    assert.equal(state.exhausted, true);
  });

  describe("the backoff schedule", () => {
    it("starts fast and grows", () => {
      assert.ok(reconnectDelayMs(1) < reconnectDelayMs(5));
      assert.ok(reconnectDelayMs(5) < reconnectDelayMs(RECONNECT_BUDGET));
    });

    it("is bounded past the end of the schedule", () => {
      assert.equal(reconnectDelayMs(50), reconnectDelayMs(RECONNECT_BUDGET));
    });

    it("never returns a nonsense delay", () => {
      for (const tries of [0, -3, 1.5]) {
        assert.ok(Number.isFinite(reconnectDelayMs(tries)) && reconnectDelayMs(tries) > 0);
      }
    });

    it("knows when the budget is spent", () => {
      assert.equal(budgetSpent(RECONNECT_BUDGET - 1), false);
      assert.equal(budgetSpent(RECONNECT_BUDGET), true);
    });
  });
});
