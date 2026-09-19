import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  OFFLINE_BANNER,
  SUMMARY_STATES,
  degradedState,
  describeConnection,
  isOfflineState,
  storageLine,
  summaryState,
} from "./connection_model.ts";

describe("which of the six states we are in (spec §7)", () => {
  it("names all six", () => {
    assert.deepEqual([...SUMMARY_STATES], [
      "connecting",
      "live",
      "reconnecting",
      "offline-pending",
      "offline-idle",
      "error",
    ]);
  });

  it("reads the connection through, with no pending work", () => {
    assert.equal(summaryState({ connection: "connecting", pendingCount: 0, fatal: null }), "connecting");
    assert.equal(summaryState({ connection: "live", pendingCount: 0, fatal: null }), "live");
    assert.equal(
      summaryState({ connection: "reconnecting", pendingCount: 0, fatal: null }),
      "reconnecting",
    );
    assert.equal(
      summaryState({ connection: "offline", pendingCount: 0, fatal: null }),
      "offline-idle",
    );
  });

  it("splits offline by whether the user has work waiting", () => {
    assert.equal(
      summaryState({ connection: "offline", pendingCount: 2, fatal: null }),
      "offline-pending",
    );
  });

  it("does not call it offline-with-work while we are still trying", () => {
    assert.equal(
      summaryState({ connection: "reconnecting", pendingCount: 3, fatal: null }),
      "reconnecting",
    );
  });

  it("lets an unrecoverable client error beat every connection state", () => {
    for (const connection of ["connecting", "live", "reconnecting", "offline"] as const) {
      assert.equal(summaryState({ connection, pendingCount: 0, fatal: "boom" }), "error");
    }
  });

  it("is one derivation for the summary and the local signifiers (m04.03 5.1.2)", () => {
    assert.equal(degradedState, summaryState);
  });

  it("counts only the two offline states as offline (m04.03 5.3)", () => {
    assert.equal(isOfflineState("offline-idle"), true);
    assert.equal(isOfflineState("offline-pending"), true);
    for (const state of ["connecting", "live", "reconnecting", "error"] as const) {
      assert.equal(isOfflineState(state), false, `${state} greyed the controls out`);
    }
  });

  it("names the offline banner in the user's terms", () => {
    assert.match(OFFLINE_BANNER, /^Offline — /);
    assert.match(OFFLINE_BANNER, /kept on this device/);
  });
});

describe("how each state is presented (spec §7: never colour alone)", () => {
  it("gives every state a label, an icon and a tone", () => {
    for (const state of SUMMARY_STATES) {
      const shown = describeConnection(state);
      assert.ok(shown.label.length > 0, `${state} has no label`);
      assert.ok(shown.icon.length > 0, `${state} has no icon`);
      assert.ok(shown.tone.length > 0, `${state} has no tone`);
      assert.equal(shown.state, state);
    }
  });

  it("gives every state its OWN label — the text is the signal, not the colour", () => {
    const labels = SUMMARY_STATES.map((state) => describeConnection(state).label);
    assert.equal(new Set(labels).size, labels.length, labels.join(" / "));
  });

  it("counts the waiting work in the label, so the count is readable text", () => {
    assert.match(describeConnection("offline-pending", 1).label, /1 change/);
    assert.match(describeConnection("offline-pending", 3).label, /3 changes/);
  });

  it("offers Retry when the client has stopped trying, and Reload when it is broken", () => {
    assert.equal(describeConnection("offline-idle").action, "retry");
    assert.equal(describeConnection("offline-pending").action, "retry");
    assert.equal(describeConnection("error").action, "reload");
    assert.equal(describeConnection("live").action, null);
    assert.equal(describeConnection("connecting").action, null);
    assert.equal(describeConnection("reconnecting").action, null);
  });

  it("keeps the live state quiet on screen but present for assistive tech", () => {
    const live = describeConnection("live");
    assert.equal(live.quiet, true);
    assert.equal(describeConnection("reconnecting").quiet, false);
  });

  it("spins only while something is actually in flight", () => {
    assert.equal(describeConnection("connecting").spin, true);
    assert.equal(describeConnection("reconnecting").spin, true);
    assert.equal(describeConnection("offline-idle").spin, false);
    assert.equal(describeConnection("error").spin, false);
  });
});

describe("the local-cache line underneath (item 3.4)", () => {
  it("says nothing while the cache is fine", () => {
    assert.equal(storageLine("opening", null), null);
    assert.equal(storageLine("ready", null), null);
  });

  it("tells the user plainly when this browser is not keeping a copy", () => {
    const line = storageLine("unavailable", null);
    assert.ok(line !== null && line.length > 0);
    assert.doesNotMatch(String(line), /IndexedDB|quota/i, "no plumbing in the user's sentence");
  });

  it("appends the reason when there is one", () => {
    assert.match(String(storageLine("degraded", "out of space")), /out of space/);
  });

  it("warns against a reload when the memory-only queue holds work (m04.03 5.1.2)", () => {
    assert.match(String(storageLine("unavailable", null, 1)), /don’t reload until your 1 change has been sent/);
    assert.match(String(storageLine("unavailable", null, 3)), /3 changes have been sent/);
    assert.doesNotMatch(String(storageLine("unavailable", null, 0)), /don’t reload/);
    assert.doesNotMatch(String(storageLine("degraded", null, 3)), /don’t reload/, "a degraded store still keeps the queue");
  });
});
