import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { runSignOut } from "./sign_out_flow.ts";

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
