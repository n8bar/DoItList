import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { ICON_NAMES } from "../ui/icons.ts";
import {
  THEME_SEGMENTS,
  segmentClass,
  themeGroupClass,
  themeSegmentId,
} from "./theme_toggle_model.ts";

describe("the theme control is the LiveView's three-way group (item 4.7)", () => {
  it("offers System, Light and Dark, in that order", () => {
    assert.deepEqual(
      THEME_SEGMENTS.map((segment) => segment.preference),
      ["system", "light", "dark"],
    );
    assert.deepEqual(
      THEME_SEGMENTS.map((segment) => segment.label),
      ["System", "Light", "Dark"],
    );
  });

  it("names every segment the way the LiveView header names it", () => {
    assert.deepEqual(
      THEME_SEGMENTS.map((segment) => segment.ariaLabel),
      ["Use system theme", "Use light theme", "Use dark theme"],
    );
    for (const segment of THEME_SEGMENTS) {
      assert.ok(segment.title.trim().length > 0, `${segment.preference} has no title`);
    }
  });

  it("asks for real icons", () => {
    for (const segment of THEME_SEGMENTS) {
      assert.ok(ICON_NAMES.includes(segment.icon), `${segment.preference} uses an unknown icon`);
    }
  });

  it("derives a distinct dom id per segment from the control's id", () => {
    const ids = THEME_SEGMENTS.map((segment) => themeSegmentId("client-theme", segment.preference));
    assert.equal(new Set(ids).size, ids.length);
    for (const id of ids) assert.ok(id.startsWith("client-theme-"));
  });
});

describe("the segment styles", () => {
  it("marks only the active segment, and marks it with more than colour", () => {
    const active = segmentClass({ active: true, position: 0 });
    const idle = segmentClass({ active: false, position: 0 });
    assert.notEqual(active, idle);
    assert.match(active, /font-semibold/);
  });

  it("joins the segments: only the middle and last carry a divider", () => {
    assert.doesNotMatch(segmentClass({ active: false, position: 0 }), /border-l/);
    assert.match(segmentClass({ active: false, position: 1 }), /border-l/);
    assert.match(segmentClass({ active: false, position: 2 }), /border-l/);
  });

  it("holds a 44px touch target that relaxes only past sm:", () => {
    const classes = segmentClass({ active: false, position: 1 });
    assert.match(classes, /\bmin-h-11\b/);
    assert.match(classes, /\bmin-w-11\b/);
    assert.match(classes, /\bsm:min-h-9\b/);
  });

  it("gives the group one fixed shape, whichever segment is on", () => {
    // Nothing state-dependent in the wrapper: the group cannot resize when the
    // user presses a segment, so its neighbours cannot be shoved sideways.
    assert.equal(themeGroupClass(), themeGroupClass());
    assert.match(themeGroupClass(), /inline-flex/);
    assert.match(themeGroupClass(true), /w-full/);
  });
});
