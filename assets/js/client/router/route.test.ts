import assert from "node:assert/strict";
import { describe, it } from "node:test";

import { HOME_PATH, internalPath, matchRoute, parseId, routePath, sameRoute } from "./route.ts";

describe("matchRoute", () => {
  it("resolves the four product paths", () => {
    assert.deepEqual(matchRoute("/app/initiatives"), { kind: "initiatives" });
    assert.deepEqual(matchRoute("/app/initiatives/42"), { kind: "initiative", id: 42 });
    assert.deepEqual(matchRoute("/app/assigned"), { kind: "assigned" });
    assert.deepEqual(matchRoute("/app/account"), { kind: "account" });
  });

  it("redirects a bare /app to the Initiatives index", () => {
    assert.deepEqual(matchRoute("/app"), { kind: "redirect", to: HOME_PATH });
    assert.deepEqual(matchRoute("/app/"), { kind: "redirect", to: HOME_PATH });
  });

  it("ignores trailing slashes", () => {
    assert.deepEqual(matchRoute("/app/initiatives/"), { kind: "initiatives" });
    assert.deepEqual(matchRoute("/app/initiatives/42/"), { kind: "initiative", id: 42 });
    assert.deepEqual(matchRoute("/app/account//"), { kind: "account" });
  });

  it("treats an unreadable Initiative id as not found", () => {
    for (const path of [
      "/app/initiatives/abc",
      "/app/initiatives/0",
      "/app/initiatives/-1",
      "/app/initiatives/1.5",
      "/app/initiatives/1e3",
      "/app/initiatives/%20",
    ]) {
      assert.deepEqual(matchRoute(path), { kind: "not-found", path }, path);
    }
  });

  it("treats unknown paths, deeper paths and off-app paths as not found", () => {
    for (const path of [
      "/app/nope",
      "/app/initiatives/42/tasks",
      "/app/assigned/extra",
      "/initiatives",
      "/",
      "/appx/initiatives",
    ]) {
      assert.equal(matchRoute(path).kind, "not-found", path);
    }
  });

  it("never throws on a missing or empty pathname", () => {
    assert.equal(matchRoute("").kind, "not-found");
  });
});

describe("parseId", () => {
  it("accepts positive integers only", () => {
    assert.equal(parseId("1"), 1);
    assert.equal(parseId("4200"), 4200);
    assert.equal(parseId("007"), 7);
    assert.equal(parseId("0"), null);
    assert.equal(parseId("-3"), null);
    assert.equal(parseId("3x"), null);
    assert.equal(parseId(""), null);
    assert.equal(parseId("99999999999999999999"), null);
  });
});

describe("routePath", () => {
  it("round-trips every route through matchRoute", () => {
    for (const route of [
      { kind: "initiatives" } as const,
      { kind: "initiative", id: 12 } as const,
      { kind: "assigned" } as const,
      { kind: "account" } as const,
    ]) {
      assert.deepEqual(matchRoute(routePath(route)), route);
    }
  });
});

describe("internalPath", () => {
  it("claims /app and its children, and nothing else", () => {
    assert.equal(internalPath("/app"), true);
    assert.equal(internalPath("/app/initiatives/1"), true);
    assert.equal(internalPath("/initiatives"), false);
    assert.equal(internalPath("/appx"), false);
    assert.equal(internalPath("https://example.com/app"), false);
  });
});

describe("sameRoute", () => {
  it("distinguishes routes that render different screens", () => {
    assert.equal(sameRoute({ kind: "initiatives" }, { kind: "initiatives" }), true);
    assert.equal(sameRoute({ kind: "initiative", id: 1 }, { kind: "initiative", id: 1 }), true);
    assert.equal(sameRoute({ kind: "initiative", id: 1 }, { kind: "initiative", id: 2 }), false);
    assert.equal(sameRoute({ kind: "initiatives" }, { kind: "account" }), false);
    assert.equal(
      sameRoute({ kind: "not-found", path: "/app/a" }, { kind: "not-found", path: "/app/b" }),
      false,
    );
  });

  it("sees a trailing slash as the same screen", () => {
    assert.equal(sameRoute(matchRoute("/app/account"), matchRoute("/app/account/")), true);
    assert.equal(
      sameRoute(matchRoute("/app/initiatives/42"), matchRoute("/app/initiatives/42/")),
      true,
    );
  });
});
