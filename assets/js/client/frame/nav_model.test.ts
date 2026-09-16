import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { matchRoute } from "../router/route.ts";
import { NAV_ITEMS, activeNavKey, isCurrentNav } from "./nav_model.ts";

describe("the primary nav model", () => {
  it("names every section once, with a text label and an in-app path", () => {
    assert.deepEqual(
      NAV_ITEMS.map((item) => item.key),
      ["initiatives", "assigned", "account"],
    );
    for (const item of NAV_ITEMS) {
      assert.notEqual(item.label, "", `${item.key} has no label`);
      assert.match(item.to, /^\/app\//, `${item.key} does not point into the app`);
    }
  });

  it("marks the entry whose route is showing", () => {
    assert.equal(activeNavKey(matchRoute("/app/initiatives")), "initiatives");
    assert.equal(activeNavKey(matchRoute("/app/assigned")), "assigned");
    assert.equal(activeNavKey(matchRoute("/app/account")), "account");
  });

  it("keeps one Initiative under Initiatives", () => {
    assert.equal(activeNavKey(matchRoute("/app/initiatives/12")), "initiatives");
    assert.equal(isCurrentNav(matchRoute("/app/initiatives/12"), "initiatives"), true);
    assert.equal(isCurrentNav(matchRoute("/app/initiatives/12"), "assigned"), false);
  });

  it("marks nothing when the route is outside the nav", () => {
    assert.equal(activeNavKey(matchRoute("/app/nope")), null);
    assert.equal(activeNavKey(matchRoute("/app")), null);
    for (const item of NAV_ITEMS) {
      assert.equal(isCurrentNav(matchRoute("/app/nope"), item.key), false);
    }
  });

  it("never marks two entries at once", () => {
    for (const path of ["/app/initiatives", "/app/initiatives/3", "/app/assigned", "/app/account"]) {
      const route = matchRoute(path);
      const marked = NAV_ITEMS.filter((item) => isCurrentNav(route, item.key));
      assert.equal(marked.length, 1, `${path} marked ${marked.length} entries`);
    }
  });
});
