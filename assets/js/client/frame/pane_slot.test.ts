import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { addTenant, paneVisible, removeTenant } from "./pane_slot.ts";

describe("the pane slot's occupancy", () => {
  it("shows the column only while somebody is in it", () => {
    assert.equal(paneVisible(0), false);
    assert.equal(paneVisible(1), true);
    assert.equal(paneVisible(2), true);
  });

  it("opens on the first tenant and closes on the last", () => {
    let count = 0;
    count = addTenant(count);
    assert.equal(paneVisible(count), true);
    count = addTenant(count);
    count = removeTenant(count);
    assert.equal(paneVisible(count), true, "the second tenant closed the column");
    count = removeTenant(count);
    assert.equal(paneVisible(count), false);
  });

  it("never goes negative, so a stray release cannot strand the column", () => {
    assert.equal(removeTenant(0), 0);
    assert.equal(paneVisible(addTenant(removeTenant(removeTenant(0)))), true);
  });
});
