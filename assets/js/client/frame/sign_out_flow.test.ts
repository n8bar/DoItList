import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { confirmSignOut, runSignOut, unsavedSentence } from "./sign_out_flow.ts";

/** Records the order things happened in. */
function recorder() {
  const order: string[] = [];
  return { order, note: (what: string) => () => order.push(what) };
}

describe("signing out", () => {
  it("purges, submits, and only then lets the caller tidy up", async () => {
    const { order, note } = recorder();
    const purged = await runSignOut({
      cache: {
        purge: async () => {
          order.push("purge");
          return true;
        },
      },
      submit: note("submit"),
      afterSubmit: note("close"),
    });

    assert.equal(purged, true);
    assert.deepEqual(order, ["purge", "submit", "close"]);
  });

  // The regression: closing the menu unmounts the form, so it must never happen
  // before the request has gone.
  it("never closes the menu before the request is sent", async () => {
    const { order, note } = recorder();
    await runSignOut({
      cache: { purge: () => Promise.resolve().then(() => true) },
      submit: note("submit"),
      afterSubmit: note("close"),
    });

    assert.ok(order.indexOf("submit") < order.indexOf("close"), order.join(" → "));
  });

  it("still submits when the purge never finishes, and still in order", async () => {
    const { order, note } = recorder();
    const purged = await runSignOut({
      cache: { purge: () => new Promise<boolean>(() => {}) },
      submit: note("submit"),
      afterSubmit: note("close"),
      timeoutMs: 10,
    });

    assert.equal(purged, false, "a hung purge must not report success");
    assert.deepEqual(order, ["submit", "close"]);
  });

  it("still submits when the purge throws outright", async () => {
    const { order, note } = recorder();
    const purged = await runSignOut({
      cache: {
        purge: () => {
          throw new Error("the browser refused to delete anything");
        },
      },
      submit: note("submit"),
      afterSubmit: note("close"),
    });

    assert.equal(purged, false);
    assert.deepEqual(order, ["submit", "close"]);
  });

  it("works without a tidy-up", async () => {
    const { order, note } = recorder();
    await runSignOut({ cache: { purge: async () => true }, submit: note("submit") });
    assert.deepEqual(order, ["submit"]);
  });
});

describe("the warning before sign-out (m04.03 2.4.1)", () => {
  it("asks only when the device holds unsaved work", () => {
    assert.equal(confirmSignOut(0), false);
    assert.equal(confirmSignOut(1), true);
    assert.equal(confirmSignOut(3), true);
  });

  it("says how much would go", () => {
    assert.match(unsavedSentence(1), /^One change/);
    assert.match(unsavedSentence(4), /^4 changes/);
  });
});
