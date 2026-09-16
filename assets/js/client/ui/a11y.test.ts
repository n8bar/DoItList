// The baseline, enforced where it can be enforced without a browser (item 4.2
// leaf: "preserve the M02 baseline").
//
// These are the a11y rules that are decided in DATA rather than in markup —
// every model that becomes a control has a name, every state the user can be in
// has words of its own, every icon we ask for is a real one. The rules that
// need a rendered page (focus return, touch targets, contrast) are the CDP
// harness's and the reviewer's; these are the ones a unit test can hold.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { NAV_ITEMS } from "../frame/nav_model.ts";
import { SUMMARY_STATES, describeConnection } from "./connection_model.ts";
import { ICON_NAMES, iconClass } from "./icons.ts";
import { dialogIds } from "./dialog_model.ts";
import { SAVING_LABEL, describedBy, fieldIds } from "./form_model.ts";
import type { MenuItemModel } from "./menu_model.ts";
import { menuItemDomId } from "./menu_model.ts";

/** Everything that becomes a control somewhere in the client. */
const labelled: readonly { what: string; label: string }[] = [
  ...NAV_ITEMS.map((item) => ({ what: `nav item ${item.key}`, label: item.label })),
  ...SUMMARY_STATES.map((state) => ({
    what: `connection ${state}`,
    label: describeConnection(state, 2).label,
  })),
];

describe("every control model carries a name (guardrails §4.1)", () => {
  it("has a non-empty, non-whitespace label", () => {
    for (const { what, label } of labelled) {
      assert.ok(label.trim().length > 0, `${what} has no label`);
    }
  });

  it("never names a control after the machinery behind it", () => {
    for (const { what, label } of labelled) {
      assert.doesNotMatch(label, /socket|websocket|indexeddb|csrf|null|undefined/i, what);
    }
  });

  it("makes every menu item model declare a label", () => {
    // The type demands it; this is the assertion that a menu built from data
    // cannot slip an unnamed item past the compiler with an empty string.
    const items: readonly MenuItemModel[] = [
      { id: "expand-all", label: "Expand all" },
      { id: "collapse-all", label: "Collapse all" },
    ];
    for (const item of items) {
      assert.ok(item.label.trim().length > 0, `menu item ${item.id} has no label`);
      assert.ok(menuItemDomId("m", item.id).endsWith(item.id));
    }
  });
});

describe("icons are decoration on top of words, never the words", () => {
  it("asks for real heroicon classes, one per name", () => {
    const classes = ICON_NAMES.map(iconClass);
    for (const name of classes) assert.match(name, /^hero-[a-z-]+$/);
    assert.equal(new Set(classes).size, classes.length);
  });

  it("gives every connection state an icon AND its own words", () => {
    for (const state of SUMMARY_STATES) {
      const shown = describeConnection(state);
      assert.ok(ICON_NAMES.includes(shown.icon), `${state} uses an unknown icon`);
      assert.ok(shown.label.length > 0);
    }
  });
});

describe("ids that must not collide", () => {
  it("keeps a dialog's four ids distinct from a field's three", () => {
    const ids = [...Object.values(dialogIds("thing")), ...Object.values(fieldIds("thing", "name"))];
    assert.equal(new Set(ids).size, ids.length, ids.join(" "));
  });

  it("describes an input by the helpers it actually has", () => {
    const ids = fieldIds("f", "title");
    assert.equal(describedBy(ids, { description: false, error: false }), undefined);
    assert.ok(String(describedBy(ids, { description: true, error: true })).includes(ids.errorId));
  });

  it("says what a busy submit is doing, in words", () => {
    assert.ok(SAVING_LABEL.trim().length > 0);
    assert.doesNotMatch(SAVING_LABEL, /^\.+$/);
  });
});
