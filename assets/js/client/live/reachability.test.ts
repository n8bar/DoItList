import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { NetworkSignal } from "./network.ts";
import {
  PROBE_CAP_MS,
  PROBE_JITTER_RATIO,
  PROBE_START_MS,
  createReachabilityProbe,
  probeDelayMs,
} from "./reachability.ts";
import type { VisibilitySignal } from "./reachability.ts";

/** Timers that remember their delay, so the schedule itself is asserted. */
function clock() {
  const pending = new Map<number, { callback: () => void; ms: number }>();
  let next = 0;
  return {
    timers: {
      setTimeout(callback: () => void, ms: number) {
        next += 1;
        pending.set(next, { callback, ms });
        return next;
      },
      clearTimeout(handle: unknown) {
        pending.delete(handle as number);
      },
    },
    delays: () => [...pending.values()].map((entry) => entry.ms),
    count: () => pending.size,
    /** Fire every timer that is currently due (they run in order). */
    async flush() {
      const due = [...pending.entries()];
      pending.clear();
      for (const [, entry] of due) entry.callback();
      // Let the probe's promise settle.
      await Promise.resolve();
      await Promise.resolve();
    },
  };
}

function network(online = true) {
  let listener: ((online: boolean) => void) | null = null;
  let state = online;
  const signal: NetworkSignal = {
    online: () => state,
    subscribe(onChange) {
      listener = onChange;
      return () => {
        listener = null;
      };
    },
  };
  return {
    signal,
    go(next: boolean) {
      state = next;
      listener?.(next);
    },
  };
}

function visibility(hidden = false) {
  let listener: ((hidden: boolean) => void) | null = null;
  let state = hidden;
  const signal: VisibilitySignal = {
    hidden: () => state,
    subscribe(onChange) {
      listener = onChange;
      return () => {
        listener = null;
      };
    },
  };
  return {
    signal,
    go(next: boolean) {
      state = next;
      listener?.(next);
    },
  };
}

function harness(options: { reachable?: () => boolean; online?: boolean; hidden?: boolean } = {}) {
  const time = clock();
  const net = network(options.online ?? true);
  const vis = visibility(options.hidden ?? false);
  const reachable = options.reachable ?? (() => false);
  let probes = 0;
  let restored = 0;
  const probe = createReachabilityProbe({
    probe: () => {
      probes += 1;
      return Promise.resolve(reachable());
    },
    onReachable: () => {
      restored += 1;
    },
    timers: time.timers,
    network: net.signal,
    visibility: vis.signal,
    random: () => 0.5,
  });
  return { probe, time, net, vis, probes: () => probes, restored: () => restored };
}

describe("the probe's cadence (m04.03 5.2.3)", () => {
  const mid = () => 0.5;
  const low = () => 0;
  const high = () => 1 - Number.EPSILON;

  it("starts at fifteen seconds and doubles to a two-minute cap", () => {
    assert.equal(probeDelayMs(1, mid), PROBE_START_MS);
    assert.equal(probeDelayMs(2, mid), PROBE_START_MS * 2);
    assert.equal(probeDelayMs(3, mid), PROBE_START_MS * 4);
    assert.equal(probeDelayMs(4, mid), PROBE_CAP_MS);
    assert.equal(probeDelayMs(9, mid), PROBE_CAP_MS);
  });

  it("jitters both ways within the ratio and never past the cap", () => {
    assert.equal(probeDelayMs(1, low), Math.round(PROBE_START_MS * (1 - PROBE_JITTER_RATIO)));
    assert.equal(probeDelayMs(1, high), Math.round(PROBE_START_MS * (1 + PROBE_JITTER_RATIO)));
    assert.ok(probeDelayMs(6, high) <= PROBE_CAP_MS);
    assert.ok(probeDelayMs(0, mid) > 0);
  });
});

describe("when the probe runs", () => {
  it("books nothing until the connection is offline", () => {
    const h = harness();
    h.probe.setStatus("connecting");
    h.probe.setStatus("reconnecting");
    assert.equal(h.time.count(), 0, "a client still retrying needs no probe");
  });

  it("probes at the schedule while offline, and a failure books the next one slower", async () => {
    const h = harness();
    h.probe.setStatus("offline");
    assert.deepEqual(h.time.delays(), [PROBE_START_MS]);

    await h.time.flush();
    assert.equal(h.probes(), 1);
    assert.deepEqual(h.time.delays(), [PROBE_START_MS * 2]);

    await h.time.flush();
    assert.equal(h.probes(), 2);
    assert.deepEqual(h.time.delays(), [PROBE_START_MS * 4]);
    assert.equal(h.restored(), 0);
  });

  it("calls the retry path once when a probe lands, and books no more", async () => {
    const h = harness({ reachable: () => true });
    h.probe.setStatus("offline");
    await h.time.flush();

    assert.equal(h.restored(), 1);
    assert.equal(h.time.count(), 0, "a visible reconnect loop is exactly what this must not be");
    // The retry re-opens the socket: the status moves and the probe stays quiet.
    h.probe.setStatus("connecting");
    h.probe.setStatus("live");
    assert.equal(h.time.count(), 0);
  });

  it("stops the moment the connection is live again", () => {
    const h = harness();
    h.probe.setStatus("offline");
    h.probe.setStatus("connecting");
    assert.equal(h.time.count(), 0);
  });

  it("starts the schedule over each time the client goes offline", async () => {
    const h = harness();
    h.probe.setStatus("offline");
    await h.time.flush();
    assert.deepEqual(h.time.delays(), [PROBE_START_MS * 2]);
    h.probe.setStatus("connecting");
    h.probe.setStatus("offline");
    assert.deepEqual(h.time.delays(), [PROBE_START_MS]);
  });

  it("does not probe while the browser says there is no network, and books one when it says there is", () => {
    const h = harness({ online: false });
    h.probe.setStatus("offline");
    assert.equal(h.time.count(), 0);

    h.net.go(true);
    assert.deepEqual(h.time.delays(), [PROBE_START_MS]);

    h.net.go(false);
    assert.equal(h.time.count(), 0, "a booked probe is cancelled when the network goes");
  });

  it("pauses in a hidden tab and resumes when it is shown", async () => {
    const h = harness();
    h.probe.setStatus("offline");
    h.vis.go(true);
    assert.equal(h.time.count(), 0);

    h.vis.go(false);
    assert.deepEqual(h.time.delays(), [PROBE_START_MS * 2], "the schedule carries on where it was");
    await h.time.flush();
    assert.equal(h.probes(), 1);
  });

  it("books nothing in a tab that was hidden when the client went offline", () => {
    const h = harness({ hidden: true });
    h.probe.setStatus("offline");
    assert.equal(h.time.count(), 0);
    h.vis.go(false);
    assert.equal(h.time.count(), 1);
  });

  it("a probe due while hidden does not go out", async () => {
    const h = harness();
    h.probe.setStatus("offline");
    h.vis.signal.hidden = () => true;
    await h.time.flush();
    assert.equal(h.probes(), 0);
  });

  it("never fires after stop", async () => {
    const h = harness({ reachable: () => true });
    h.probe.setStatus("offline");
    h.probe.stop();
    await h.time.flush();
    assert.equal(h.probes(), 0);
    h.vis.go(true);
    h.vis.go(false);
    h.net.go(true);
    assert.equal(h.time.count(), 0);
  });
});
