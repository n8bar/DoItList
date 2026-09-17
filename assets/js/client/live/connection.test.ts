import assert from "node:assert/strict";
import { beforeEach, describe, it } from "node:test";

import type { ChangedEvent, ConnectionDeps, PresenceEvent } from "./connection.ts";
import { createConnection, getConnection, initConnection, parseChanged, resetConnection } from "./connection.ts";
import type { ConnectionStatus } from "../state/recovery.ts";
import { RECONNECT_BUDGET } from "./connection_state.ts";
import { fakeTimers, fakeTransport } from "./fake_transport.ts";
import type { NetworkSignal } from "./network.ts";
import { matchRoute } from "../router/route.ts";

function harness(overrides: Partial<ConnectionDeps> = {}) {
  const socket = fakeTransport();
  const clock = fakeTimers();
  const statuses: ConnectionStatus[] = [];
  const changes: ChangedEvent[] = [];
  const revoked: number[] = [];
  const presence: Array<{ initiativeId: number; event: PresenceEvent }> = [];

  const connection = createConnection({
    transport: socket.factory,
    onStatus: (status) => statuses.push(status),
    onChanged: (event) => changes.push(event),
    onAccessRevoked: (id) => revoked.push(id),
    onPresence: (initiativeId, event) => presence.push({ initiativeId, event }),
    // Mid-jitter, so the delays a test reads back are the scheduled ones.
    random: () => 0.5,
    timers: clock.timers,
    leaveGraceMs: 5_000,
    ...overrides,
  });

  return { connection, socket, clock, statuses, changes, revoked, presence };
}

/** A connection that is up, with the socket open. */
function live(overrides: Partial<ConnectionDeps> = {}) {
  const h = harness(overrides);
  h.connection.connect();
  h.socket.get().open();
  return h;
}

const bareDeps = (socket: ReturnType<typeof fakeTransport>): ConnectionDeps => ({
  transport: socket.factory,
  onStatus: () => {},
  onChanged: () => {},
  onAccessRevoked: () => {},
});

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
    const { connection, socket } = live();
    socket.get().fail();

    assert.equal(connection.status(), "reconnecting");
    assert.equal(socket.get().disconnects, 0, "Phoenix is still retrying on its own");
  });

  it("spends ONE attempt on one failed connect, not two", () => {
    // A failed attempt fires `onerror` AND `onclose`; the fake emits both, in
    // Phoenix's order, so a budget counted off callbacks fails here.
    const { connection, socket } = live();
    for (let i = 0; i < RECONNECT_BUDGET; i += 1) socket.get().fail();

    assert.equal(socket.get().tries, RECONNECT_BUDGET);
    assert.equal(connection.status(), "reconnecting", "the budget was spent twice as fast");
  });

  it("gives up once the budget runs out, stops the retry loop, and can be resumed", () => {
    const { connection, socket, clock, statuses } = live();
    for (let i = 0; i <= RECONNECT_BUDGET; i += 1) socket.get().fail();

    assert.equal(connection.status(), "offline");
    assert.equal(socket.get().disconnects, 0, "not from inside the scheduling hook");
    clock.flush();
    assert.equal(socket.get().disconnects, 1, "the client must stop the retry loop it gave up on");

    connection.retry();
    assert.equal(connection.status(), "connecting");
    assert.equal(socket.get().connects, 2);

    socket.get().open();
    assert.equal(connection.status(), "live");
    assert.deepEqual(statuses, ["live", "reconnecting", "offline", "connecting", "live"]);
  });

  it("does not kill a connection the user retried before the teardown fired", () => {
    const { connection, socket, clock } = live();
    for (let i = 0; i <= RECONNECT_BUDGET; i += 1) socket.get().fail();
    assert.equal(connection.status(), "offline");

    // Retry lands in the same tick as the deferred teardown: the teardown must
    // not take down the connection the user just asked for.
    connection.retry();
    clock.flush();

    assert.equal(socket.get().disconnects, 0, "the fresh connection was torn down");
    assert.equal(socket.get().connects, 2);
    socket.get().open();
    assert.equal(connection.status(), "live");
  });

  it("does not resurrect itself on a route change after giving up", () => {
    const { connection, socket } = live();
    for (let i = 0; i <= RECONNECT_BUDGET; i += 1) socket.get().fail();
    assert.equal(connection.status(), "offline");

    connection.subscribeInitiative(12);
    assert.equal(socket.get().connects, 1, "only the user's retry may reconnect");
    assert.equal(connection.status(), "offline");
  });

  it("a close with no error still counts its one attempt", () => {
    const { connection, socket } = live();
    socket.get().close();
    assert.equal(connection.status(), "reconnecting");
    assert.equal(socket.get().tries, 1);
  });

  it("retry does nothing while the connection is fine", () => {
    const { connection, socket } = live();
    connection.retry();
    assert.equal(socket.get().connects, 1);
  });

  it("asks for a jittered, bounded delay on every attempt", () => {
    const { socket } = live({ random: () => 1 - Number.EPSILON });
    for (let i = 0; i < RECONNECT_BUDGET; i += 1) socket.get().fail();

    assert.equal(socket.get().delays.length, RECONNECT_BUDGET);
    for (const delay of socket.get().delays) assert.ok(delay > 0 && delay <= 5_000);
  });

  it("caps its own backoff", () => {
    const { socket } = harness();
    const delay = socket.get().options.reconnectAfterMs(RECONNECT_BUDGET * 5);
    assert.ok(delay > 0 && delay <= 5_000);
  });
});

describe("losing access mid-session", () => {
  it("drops the channel and tells the app", () => {
    const { connection, socket, revoked } = live();
    connection.subscribeInitiative(12);
    socket.get().channels[0]?.emit("access_revoked", { initiative_id: 12 });

    assert.deepEqual(revoked, [12]);
    assert.deepEqual(connection.joined(), [], "the channel must not be left joined");
    assert.deepEqual(connection.subscriptions(), []);
    assert.equal(socket.get().channels[0]?.leaves, 1);
  });

  it("keeps the rest of the session", () => {
    const { connection, socket, revoked } = live();
    connection.subscribeInitiative(12);
    connection.subscribeInitiative(13);
    socket.get().channels[0]?.emit("access_revoked", { initiative_id: 12 });

    assert.deepEqual(revoked, [12]);
    assert.deepEqual(connection.subscriptions(), [13]);
    assert.equal(connection.status(), "live");
  });
});

describe("selection presence (item 3.4.2)", () => {
  it("hands presence_state and presence_diff up as they arrive, on the Initiative that carried them", () => {
    const { connection, socket, presence } = live();
    connection.subscribeInitiative(12);
    const channel = socket.get().channels.find((c) => c.topic === "initiative:12");
    const state = { "7": { metas: [] } };
    const diff = { joins: {}, leaves: {} };
    channel?.emit("presence_state", state);
    channel?.emit("presence_diff", diff);

    assert.deepEqual(presence, [
      { initiativeId: 12, event: { kind: "state", payload: state } },
      { initiativeId: 12, event: { kind: "diff", payload: diff } },
    ]);
  });

  it("announces a selection on the joined channel, once per value", () => {
    const { connection, socket } = live();
    connection.subscribeInitiative(12);
    connection.select(12, 44);
    connection.select(12, 44);
    connection.select(12, null);

    assert.deepEqual(socket.get().channels[0]?.pushes, [
      { event: "select", payload: { task_id: 44 } },
      { event: "select", payload: { task_id: null } },
    ]);
  });

  it("remembers a selection made before the channel exists and sends it on join", () => {
    // A screen's effects run before its parent's: the tree announces before
    // the screen subscribes. The join must carry what was said.
    const { connection, socket } = live();
    connection.select(12, 44);
    assert.equal(socket.get().channels.length, 0);

    connection.subscribeInitiative(12);
    assert.deepEqual(socket.get().channels[0]?.pushes, [{ event: "select", payload: { task_id: 44 } }]);
  });

  it("says nothing on join when nothing is selected", () => {
    const { connection, socket } = live();
    connection.subscribeInitiative(12);
    assert.deepEqual(socket.get().channels[0]?.pushes, []);
  });

  it("re-announces the selection when Phoenix re-joins after a drop", () => {
    const { connection, socket } = live();
    connection.subscribeInitiative(12);
    connection.select(12, 44);
    socket.get().channels[0]?.rejoin();

    assert.deepEqual(socket.get().channels[0]?.pushes, [
      { event: "select", payload: { task_id: 44 } },
      { event: "select", payload: { task_id: 44 } },
    ]);
  });

  it("keeps each Initiative's selection apart", () => {
    const { connection, socket } = live();
    connection.subscribeInitiative(12);
    connection.subscribeInitiative(13);
    connection.select(12, 1);
    connection.select(13, 2);

    assert.deepEqual(socket.get().channels[0]?.pushes, [{ event: "select", payload: { task_id: 1 } }]);
    assert.deepEqual(socket.get().channels[1]?.pushes, [{ event: "select", payload: { task_id: 2 } }]);
  });
});

describe("the tab's one connection (item 3.7)", () => {
  it("hands every caller the same object", () => {
    const { connection } = harness();
    const socket = fakeTransport();
    const built = initConnection(bareDeps(socket));
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
    initConnection({ ...bareDeps(socket), timers: clock.timers });
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
    const { connection, socket } = live();
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

  it("retry does nothing once the connection has been disconnected", () => {
    // disconnect() has already dropped the network watcher and every
    // channel; retry() standing a socket back up here would leave it with
    // nothing wired to it.
    const { connection, socket } = live();
    connection.disconnect();
    assert.equal(connection.status(), "offline");

    connection.retry();

    assert.equal(socket.get().connects, 1, "disconnect must not be undone by retry");
    assert.equal(connection.status(), "offline");
  });

  it("only a new tab gets a new connection", () => {
    const socket = fakeTransport();
    const deps = bareDeps(socket);
    const before = initConnection(deps).id;
    resetConnection();
    assert.notEqual(initConnection(deps).id, before);
  });
});

describe("the browser says the network went away (spec §7)", () => {
  function fakeNetwork(initialOnline = true) {
    let online = initialOnline;
    let listener: ((online: boolean) => void) | null = null;
    let unsubscribed = false;
    const signal: NetworkSignal = {
      online: () => online,
      subscribe(onChange) {
        listener = onChange;
        return () => {
          unsubscribed = true;
        };
      },
    };
    return {
      signal,
      go: (next: boolean) => {
        online = next;
        listener?.(next);
      },
      unsubscribed: () => unsubscribed,
    };
  }

  it("stops saying Live the moment the machine loses its network", () => {
    const net = fakeNetwork();
    const h = live({ network: net.signal });
    assert.equal(h.connection.status(), "live");

    net.go(false);

    assert.equal(h.connection.status(), "offline");
    assert.equal(h.socket.get().disconnects, 1);
  });

  it("does not come back on its own — the way back is the user's click", () => {
    const net = fakeNetwork();
    const h = live({ network: net.signal });

    net.go(false);
    net.go(true);
    assert.equal(h.connection.status(), "offline");

    h.connection.retry();
    assert.equal(h.connection.status(), "connecting");
    h.socket.get().open();
    assert.equal(h.connection.status(), "live");
  });

  it("says it once, however many times the browser repeats itself", () => {
    const net = fakeNetwork();
    const h = live({ network: net.signal });

    net.go(false);
    net.go(false);

    assert.deepEqual(h.statuses.slice(-1), ["offline"]);
    assert.equal(h.statuses.filter((s) => s === "offline").length, 1);
  });

  it("lets go of the browser when the connection is torn down", () => {
    const net = fakeNetwork();
    const h = live({ network: net.signal });

    h.connection.disconnect();

    assert.equal(net.unsubscribed(), true);
  });

  it("says offline right away when a tab boots with no network at all", () => {
    const net = fakeNetwork(false);
    const h = harness({ network: net.signal });

    h.connection.connect();

    assert.equal(h.connection.status(), "offline");
    assert.equal(h.socket.get().connects, 0, "must not open a socket with no network");
  });

  it("connects once the user retries after the network comes back", () => {
    const net = fakeNetwork(false);
    const h = harness({ network: net.signal });
    h.connection.connect();
    assert.equal(h.connection.status(), "offline");

    net.go(true);
    h.connection.retry();

    assert.equal(h.connection.status(), "connecting");
    assert.equal(h.socket.get().connects, 1);
  });
});

describe("the user's own channel (item 4.6.2)", () => {
  it("joins user:<id> once, however many times it is asked", () => {
    const h = live();
    h.connection.watchUser(7);
    h.connection.watchUser(7);

    const mine = h.socket.get().channels.filter((c) => c.topic === "user:7");
    assert.equal(mine.length, 1);
    assert.equal(mine[0]?.joins, 1);
  });

  it("hands a notification straight to the app", () => {
    const seen: unknown[] = [];
    const h = live({ onNotification: (row) => seen.push(row) });
    h.connection.watchUser(7);

    const row = {
      id: 3,
      kind: "assigned",
      line: "Dana assigned you a task",
      href: "/app/initiatives/1?task=2",
      read: false,
      inserted_at: "2026-09-16T10:00:00Z",
    };
    h.socket.get().channels.find((c) => c.topic === "user:7")?.emit("notification", row);

    assert.deepEqual(seen, [row]);
  });

  it("drops a push that is not a notification row", () => {
    const seen: unknown[] = [];
    const h = live({ onNotification: (row) => seen.push(row) });
    h.connection.watchUser(7);
    const channel = h.socket.get().channels.find((c) => c.topic === "user:7");

    channel?.emit("notification", { id: "three" });
    channel?.emit("notification", null);

    assert.deepEqual(seen, []);
  });

  it("is not a per-route subscription: navigating never leaves it", () => {
    const h = live();
    h.connection.watchUser(7);
    h.connection.subscribeInitiative(1);
    h.connection.unsubscribeInitiative(1);
    h.clock.flush();

    assert.equal(h.socket.get().channels.find((c) => c.topic === "user:7")?.leaves, 0);
  });

  it("goes with the connection when it is dropped", () => {
    const h = live();
    h.connection.watchUser(7);
    h.connection.disconnect();

    assert.equal(h.socket.get().channels.find((c) => c.topic === "user:7")?.leaves, 1);
  });
});
