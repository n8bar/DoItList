import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ClickFacts } from "./click.ts";
import { handledLocally } from "./click.ts";

const plainLeftClick: ClickFacts = {
  button: 0,
  metaKey: false,
  ctrlKey: false,
  shiftKey: false,
  altKey: false,
  defaultPrevented: false,
};

describe("handledLocally", () => {
  it("handles a plain left-click on an in-app path", () => {
    assert.equal(handledLocally(plainLeftClick, "/app/initiatives/42", null), true);
    assert.equal(handledLocally(plainLeftClick, "/app/initiatives/42", ""), true);
    assert.equal(handledLocally(plainLeftClick, "/app/initiatives/42", "_self"), true);
  });

  it("leaves modifier clicks to the browser", () => {
    for (const modifier of ["metaKey", "ctrlKey", "shiftKey", "altKey"] as const) {
      const event = { ...plainLeftClick, [modifier]: true };
      assert.equal(handledLocally(event, "/app/account", null), false, modifier);
    }
  });

  it("leaves middle- and right-clicks to the browser", () => {
    assert.equal(handledLocally({ ...plainLeftClick, button: 1 }, "/app/account", null), false);
    assert.equal(handledLocally({ ...plainLeftClick, button: 2 }, "/app/account", null), false);
  });

  it("leaves an explicit target to the browser", () => {
    assert.equal(handledLocally(plainLeftClick, "/app/account", "_blank"), false);
    assert.equal(handledLocally(plainLeftClick, "/app/account", "report"), false);
  });

  it("leaves off-app paths to the browser", () => {
    assert.equal(handledLocally(plainLeftClick, "/users/log_in", null), false);
    assert.equal(handledLocally(plainLeftClick, "https://example.com/app", null), false);
  });

  it("respects a handler that already prevented the default", () => {
    const event = { ...plainLeftClick, defaultPrevented: true };
    assert.equal(handledLocally(event, "/app/account", null), false);
  });
});
