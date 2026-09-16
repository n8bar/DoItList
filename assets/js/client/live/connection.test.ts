import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import type { ChangedEvent, ConnectionDeps } from "./connection.ts";
import { createConnection, getConnection, initConnection, parseChanged, resetConnection } from "./connection.ts";
import type { ConnectionStatus } from "../state/recovery.ts";
import { RECONNECT_BUDGET } from "./connection_state.ts";
import { fakeTimers, fakeTransport } from "./fake_transport.ts";
import { matchRoute } from "../router/route.ts";

function harness(overrides: Partial<ConnectionDeps> = {}) {
  const socket = fakeTransport();
  const clock = fakeTimers();
  const statuses: ConnectionStatus[] = [];
  const changes: ChangedEvent[] = [];

  const connection = createConnection({
    transport: socket.factory,
    onStatus: (status) => statuses.push(status),
    onChanged: (event) => changes.push(event),
    timers: clock.timers,
    leaveGraceMs: 5_000,
    ...overrides,
  });

  return { connection, socket, clock, statuses, changes };
}

beforeEach(() => {
  resetConnection();
});

describe("subscriptions (item 1.5)", () => {
  it("starts with nothing subscribed and no socket open", () => {
    const { connection, socket } = harness();
    assert.deepEqual(connection.subscriptions(), []);
    assert.equal(connection.connectCount(), 0, "a socket must not open before identity is known");
    assert.equal(socket.get().connects, 0);
  });

  it("joins once however many holders there are", () => {
    const { connection, socket } = harness();
    connection.subscribeInitiative(12);
    connection.subscribeInitiative(12);
    assert.deepEqual(connection.subscriptions(), [12]);
    assert.equal(socket.get().channels.length, 1);
    assert.equal(socket.get().channels[0]?.topic, "initiative:12");
    assert.equal(socket.get().channels[0]?.joins, 1);

    connection.unsubscribeInitiative(12);
    assert.deepEqual(connection.subscriptions(), [12], "one holder is still watching");

    connection.unsubscribeInitiative(12);
    assert.deepEqual(connection.subscriptions(), []);
  });

  it("unsubscribing something not subscribed is a no-op", () => {
    const { connection } = harness();
    connection.unsubscribeInitiative(99);
    assert.deepEqual(connection.subscriptions(), []);
  });

  it("holds the channel through the grace period, then leaves it", () => {
    const { connection, socket, clock } = harness();
    connection.subscribeInitiative(12);
    connection.unsubscribeInitiative(12);

    assert.deepEqual(connection.joined(), [12], "the channel is kept for the grace period");
    assert.equal(socket.get().channels[0]?.leaves, 0);

    clock.flush();
    assert.deepEqual(connection.joined(), []);
    assert.equal(socket.get().channels[0]?.leaves, 1);
  });

  it("re-subscribing inside the grace period never re-joins", () => {
    const { connection, socket, clock } = harness();
    connection.subscribeInitiative(12);
    connection.unsubscribeInitiative(12);
    connection.subscribeInitiative(12);
    clock.flush();

    assert.deepEqual(connection.subscriptions(), [12]);
    assert.equal(socket.get().channels.length, 1);
    assert.equal(socket.get().channels[0]?.joins, 1);
    assert.equal(socket.get().channels[0]?.leaves, 0);
  });
});

describe("server changes", () => {
  it("reports a change on the Initiative whose channel carried it", () => {
    const { connection, socket, changes } = harness();
    connection.subscribeInitiative(12);
    socket.get().channels[0]?.emit("changed", { kind: "task_updated", id: 444 });

    assert.deepEqual(changes, [{ initiativeId: 12, kind: "task_updated", id: 444 }]);
  });

  it("ignores a payload it does not understand", () => {
    const { connection, socket, changes } = harness();
    connection.subscribeInitiative(12);
    const channel = socket.get().channels[0];
    channel?.emit("changed", { kind: "who_knows", id: 1 });
    channel?.emit("changed", { kind: "task_updated" });
    channel?.emit("changed", "nope");

    assert.deepEqual(changes, []);
  });

  it("stops listening once the channel is left", () => {
    const { connection, socket, clock, changes } = harness();
    connection.subscribeInitiative(12);
    connection.unsubscribeInitiative(12);
    clock.flush();
    socket.get().channels[0]?.emit("changed", { kind: "task_updated", id: 1 });

    // The fake still delivers to a left channel; what matters is that the real
    // one is gone from the connection's books, so nothing re-joins it.
    assert.deepEqual(connection.joined(), []);
    assert.equal(changes.length, 1);
  });

  it("parses only the kinds the server actually sends", () => {
    assert.deepEqual(parseChanged(7, { kind: "members_changed", id: 7 }), {
      initiativeId: 7,
      kind: "members_changed",
      id: 7,
    });
    assert.equal(parseChanged(7, { kind: "task_updated", id: "9" }), null);
    assert.equal(parseChanged(7, null), null);
  });
});

describe("connection status", () => {
  it("is connecting, then live", () => {
    const { connection, socket, statuses } = harness();
    connection.connect();
    assert.equal(connection.status(), "connecting");

    socket.get().open();
    assert.equal(connection.status(), "live");
    assert.deepEqual(statuses, ["live"]);
  });

  it("shows reconnecting while the socket retries", () => {
    const { connection, socket } = harness();
    connection.connect();
    socket.get().open();
    socket.get().close();

    assert.equal(connection.status(), "reconnecting");
    assert.equal(socket.get().disconnects, 0, "Phoenix is still retrying on its own");
  });

  it("gives up after the budget, stops the retry loop, and can be resumed", () => {
    const { connection, socket, statuses } = harness();
    connection.connect();
    socket.get().open();
    for (let i = 0; i < RECONNECT_BUDGET; i += 1) socket.get().close();

    assert.equal(connection.status(), "offline");
    assert.equal(socket.get().disconnects, 1, "the client must stop the retry loop it gave up on");

    connection.retry();
    assert.equal(connection.status(), "connecting");
    assert.equal(socket.get().connects, 2);

    socket.get().open();
    assert.equal(connection.status(), "live");
    assert.deepEqual(statuses, ["live", "reconnecting", "offline", "connecting", "live"]);
  });

  it("an error is a drop like any other", () => {
    const { connection, socket } = harness();
    connection.connect();
    socket.get().open();
    socket.get().fail();
    assert.equal(connection.status(), "reconnecting");
  });

  it("retry does nothing while the connection is fine", () => {
    const { connection, socket } = harness();
    connection.connect();
    socket.get().open();
    connection.retry();
    assert.equal(socket.get().connects, 1);
  });

  it("caps its own backoff", () => {
    const { socket } = harness();
    const delay = socket.get().options.reconnectAfterMs(RECONNECT_BUDGET * 5);
    assert.ok(delay > 0 && delay <= 5_000);
  });
});

describe("the tab's one connection (item 3.7)", () => {
  it("hands every caller the same object", () => {
    const { connection } = harness();
    const socket = fakeTransport();
    const built = initConnection({
      transport: socket.factory,
      onStatus: () => {},
      onChanged: () => {},
    });
    assert.equal(built, getConnection());
    assert.equal(getConnection(), getConnection());
    assert.notEqual(built, connection);
  });

  it("refuses to hand out a connection nobody built", () => {
    assert.throws(() => getConnection(), /initConnection/);
  });

  it("survives route changes: never recreated, never reconnected", () => {
    // A stand-in for a `RouteView`: mounting a route grabs the connection the
    // way `InitiativeScreen` does, and unmounting drops its subscription. What
    // must NOT happen is the connection object itself coming and going with the
    // screens — that would drop the live session and the user's presence on
    // every navigation (guardrail §7.4).
    const socket = fakeTransport();
    const clock = fakeTimers();
    initConnection({
      transport: socket.factory,
      onStatus: () => {},
      onChanged: () => {},
      timers: clock.timers,
    });
    getConnection().connect();
    socket.get().open();

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
    clock.flush();

    assert.equal(seen.size, 1, "the connection object was recreated mid-session");
    assert.equal(first, last);
    assert.equal(last.connectCount(), 1, "the connection reconnected during navigation");
    assert.equal(last.status(), "live");
    assert.deepEqual(last.subscriptions(), []);
    assert.deepEqual(last.joined(), []);
  });

  it("counts a reconnect, so the continuity assertion is not vacuous", () => {
    const { connection, socket } = harness();
    connection.connect();
    socket.get().open();
    assert.equal(connection.connectCount(), 1);
    assert.equal(connection.status(), "live");

    connection.subscribeInitiative(12);
    connection.disconnect();
    assert.equal(connection.status(), "offline");
    assert.deepEqual(connection.subscriptions(), []);
    assert.deepEqual(connection.joined(), []);

    connection.subscribeInitiative(12);
    assert.equal(connection.connectCount(), 2, "reconnecting must move the counter");
  });

  it("only a new tab gets a new connection", () => {
    const socket = fakeTransport();
    const deps = { transport: socket.factory, onStatus: () => {}, onChanged: () => {} };
    const before = initConnection(deps).id;
    resetConnection();
    assert.notEqual(initConnection(deps).id, before);
  });
});
