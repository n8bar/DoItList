import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { CLOSED_MENU, menuReducer } from "./menu_state.ts";

const open = menuReducer(CLOSED_MENU, { kind: "toggle" });

describe("the narrow-viewport menu", () => {
  it("starts closed and owing nobody focus", () => {
    assert.deepEqual(CLOSED_MENU, { open: false, restoreFocus: false });
  });

  it("opens and closes from the trigger, without stealing focus", () => {
    assert.equal(open.open, true);
    assert.equal(open.restoreFocus, false);

    const closed = menuReducer(open, { kind: "toggle" });
    assert.equal(closed.open, false);
    assert.equal(closed.restoreFocus, false);
  });

  it("gives focus back to the trigger when Escape closes it", () => {
    const closed = menuReducer(open, { kind: "close", reason: "escape" });
    assert.deepEqual(closed, { open: false, restoreFocus: true });
  });

  it("leaves focus alone when the user chose somewhere else to be", () => {
    for (const reason of ["outside", "navigate", "wide", "trigger"] as const) {
      const closed = menuReducer(open, { kind: "close", reason });
      assert.deepEqual(closed, { open: false, restoreFocus: false }, `reason: ${reason}`);
    }
  });

  it("pays the focus debt once", () => {
    const closed = menuReducer(open, { kind: "close", reason: "escape" });
    const paid = menuReducer(closed, { kind: "focus-restored" });
    assert.deepEqual(paid, { open: false, restoreFocus: false });
    assert.equal(menuReducer(paid, { kind: "focus-restored" }), paid);
  });

  it("ignores a close for a menu that is already closed", () => {
    assert.equal(menuReducer(CLOSED_MENU, { kind: "close", reason: "escape" }), CLOSED_MENU);
  });
});
