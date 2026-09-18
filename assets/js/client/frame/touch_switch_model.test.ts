import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  TOUCH_SWITCH_GLYPH,
  TOUCH_SWITCH_LABEL,
  touchSwitchClass,
  touchSwitchTitle,
} from "./touch_switch_model.ts";

describe("the touch layout switch (m04.02 item 7.8)", () => {
  it("is named Touch layout and shows the pointing hand", () => {
    assert.equal(TOUCH_SWITCH_LABEL, "Touch layout");
    assert.equal(TOUCH_SWITCH_GLYPH, "\u{1F446}");
  });

  it("tells on from off in words, not just colour", () => {
    assert.equal(touchSwitchTitle(true), "Touch layout: on");
    assert.equal(touchSwitchTitle(false), "Touch layout: off");
  });

  it("keeps one size whichever way it is set, and fills only when on", () => {
    const on = touchSwitchClass(true);
    const off = touchSwitchClass(false);
    assert.match(on, /bg-emerald-600/);
    assert.doesNotMatch(off, /bg-emerald-600/);
    const size = (classes: string) =>
      classes.split(" ").filter((part) => /^(sm:)?min-[hw]-/.test(part)).sort();
    assert.deepEqual(size(on), size(off));
    assert.ok(size(on).length > 0, "no size classes");
  });
});
