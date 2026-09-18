import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  NO_TENANTS,
  addTenant,
  closeTenants,
  paneOpenMarker,
  paneVisible,
  removeTenant,
} from "./pane_slot.ts";

const noop = () => {};

describe("the pane slot's occupancy", () => {
  it("shows the column only while somebody is in it", () => {
    assert.equal(paneVisible(NO_TENANTS), false);
    assert.equal(paneVisible([noop]), true);
    assert.equal(paneVisible([noop, noop]), true);
  });

  it("opens on the first tenant and closes on the last", () => {
    const a = () => {};
    const b = () => {};
    let tenants = NO_TENANTS;
    tenants = addTenant(tenants, a);
    assert.equal(paneVisible(tenants), true);
    tenants = addTenant(tenants, b);
    tenants = removeTenant(tenants, b);
    assert.equal(paneVisible(tenants), true, "the second tenant closed the column");
    tenants = removeTenant(tenants, a);
    assert.equal(paneVisible(tenants), false);
  });

  it("never goes negative, so a stray release cannot strand the column", () => {
    assert.equal(removeTenant(NO_TENANTS, noop), NO_TENANTS);
    const tenants = addTenant(removeTenant(removeTenant(NO_TENANTS, noop), noop), noop);
    assert.equal(paneVisible(tenants), true);
  });

  it("releases one instance at a time, so a double-mounted tenant counts twice", () => {
    let tenants = addTenant(addTenant(NO_TENANTS, noop), noop);
    tenants = removeTenant(tenants, noop);
    assert.equal(paneVisible(tenants), true);
    tenants = removeTenant(tenants, noop);
    assert.equal(paneVisible(tenants), false);
  });
});

describe("the flyout below lg:", () => {
  it("carries data-open while a tenant is in, and nothing when the pane is empty", () => {
    assert.equal(paneOpenMarker(NO_TENANTS), undefined);
    assert.equal(paneOpenMarker([noop]), "true");
  });

  it("Close reaches every tenant once", () => {
    let closed = 0;
    const close = () => {
      closed += 1;
    };
    closeTenants(addTenant(addTenant(NO_TENANTS, close), close));
    assert.equal(closed, 1, "a double-mounted tenant was closed twice");
    closeTenants(NO_TENANTS);
    assert.equal(closed, 1);
  });
});
