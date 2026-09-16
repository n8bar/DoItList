import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import { createConnection, getConnection, resetConnection } from "./connection.ts";
import { matchRoute } from "../router/route.ts";

beforeEach(() => {
  resetConnection();
});

describe("connection stubs", () => {
  it("starts with nothing subscribed", () => {
    assert.deepEqual(createConnection().subscriptions(), []);
  });

  it("subscribes and unsubscribes idempotently", () => {
    const connection = createConnection();
    connection.subscribeInitiative(12);
    connection.subscribeInitiative(12);
    assert.deepEqual(connection.subscriptions(), [12]);

    connection.unsubscribeInitiative(12);
    connection.unsubscribeInitiative(12);
    assert.deepEqual(connection.subscriptions(), []);
  });
});

describe("the tab's one connection (item 3.7)", () => {
  it("hands every caller the same object", () => {
    assert.equal(getConnection(), getConnection());
  });

  it("survives route changes: never recreated, never reconnected", () => {
    // A stand-in for a `RouteView`: mounting a route grabs the connection the
    // way `InitiativeScreen` does, and unmounting drops its subscription. What
    // must NOT happen is the connection object itself coming and going with the
    // screens — that would drop the live session and the user's presence on
    // every navigation (guardrail §7.4).
    const seen = new Set<string>();
    let mounted: number | null = null;

    const visit = (path: string) => {
      const connection = getConnection();
      seen.add(connection.id);

      if (mounted !== null) connection.unsubscribeInitiative(mounted);
      mounted = null;

      const route = matchRoute(path);
      if (route.kind === "initiative") {
        connection.subscribeInitiative(route.id);
        mounted = route.id;
      }
      return connection;
    };

    const first = visit("/app/initiatives");
    visit("/app/initiatives/12");
    assert.deepEqual(getConnection().subscriptions(), [12]);

    visit("/app/initiatives/13");
    assert.deepEqual(getConnection().subscriptions(), [13], "the old subscription was released");

    visit("/app/assigned");
    visit("/app/account");
    const last = visit("/app/initiatives");

    assert.equal(seen.size, 1, "the connection object was recreated mid-session");
    assert.equal(first, last);
    assert.equal(last.connectCount(), 1, "the connection reconnected during navigation");
    assert.deepEqual(last.subscriptions(), []);
  });

  it("counts a reconnect, so the continuity assertion is not vacuous", () => {
    const connection = getConnection();
    assert.equal(connection.connectCount(), 1);
    assert.equal(connection.status(), "online");

    connection.subscribeInitiative(12);
    connection.disconnect();
    assert.equal(connection.status(), "offline");
    assert.deepEqual(connection.subscriptions(), []);

    connection.subscribeInitiative(12);
    assert.equal(connection.connectCount(), 2, "reconnecting must move the counter");
  });

  it("only a new tab gets a new connection", () => {
    const before = getConnection().id;
    resetConnection();
    assert.notEqual(getConnection().id, before);
  });
});
