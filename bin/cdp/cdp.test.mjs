// Unit tests for the CDP client's request/response correlation (m04.01 item
// 1.4). No browser and no server: `createSession` takes an injected socket, so
// the ordering rules that are easy to get wrong are asserted, not assumed.
//
//   docker compose exec -T web node --test "bin/cdp/*.test.mjs"

import assert from "node:assert/strict";
import { test } from "node:test";

import { CdpError, createSession } from "./cdp.mjs";

function fakeSocket() {
  const sent = [];
  return {
    sent,
    closed: false,
    send(text) {
      sent.push(JSON.parse(text));
    },
    close() {
      this.closed = true;
    },
    /** The last frame sent, for tests that need the id the session minted. */
    last() {
      return sent[sent.length - 1];
    },
  };
}

test("send frames a command with an incrementing id", () => {
  const socket = fakeSocket();
  const session = createSession(socket);

  session.send("Page.enable");
  session.send("Runtime.evaluate", { expression: "1" });

  assert.deepEqual(socket.sent[0], { id: 1, method: "Page.enable", params: {} });
  assert.deepEqual(socket.sent[1], {
    id: 2,
    method: "Runtime.evaluate",
    params: { expression: "1" },
  });
});

test("a reply resolves the request with the matching id", async () => {
  const socket = fakeSocket();
  const session = createSession(socket);

  const first = session.send("A");
  const second = session.send("B");

  // Out of order on purpose: the id decides, not arrival order.
  session.receive(JSON.stringify({ id: 2, result: { who: "B" } }));
  session.receive(JSON.stringify({ id: 1, result: { who: "A" } }));

  assert.deepEqual(await first, { who: "A" });
  assert.deepEqual(await second, { who: "B" });
  assert.equal(session.pendingCount, 0);
});

test("a reply with no result resolves with an empty object", async () => {
  const session = createSession(fakeSocket());
  const call = session.send("Page.enable");
  session.receive(JSON.stringify({ id: 1 }));
  assert.deepEqual(await call, {});
});

test("an error reply rejects with a CdpError naming the method", async () => {
  const session = createSession(fakeSocket());
  const call = session.send("Input.dispatchMouseEvent");
  session.receive(JSON.stringify({ id: 1, error: { code: -32000, message: "bad point" } }));

  await assert.rejects(call, (error) => {
    assert.ok(error instanceof CdpError);
    assert.match(error.message, /Input\.dispatchMouseEvent: bad point/);
    assert.equal(error.code, -32000);
    return true;
  });
  assert.equal(session.pendingCount, 0);
});

test("a reply for an unknown id is ignored, not thrown", async () => {
  const session = createSession(fakeSocket());
  const call = session.send("A");
  session.receive(JSON.stringify({ id: 99, result: { stale: true } }));
  session.receive(JSON.stringify({ id: 1, result: { ok: true } }));
  assert.deepEqual(await call, { ok: true });
});

test("an unparseable frame is ignored", async () => {
  const session = createSession(fakeSocket());
  const call = session.send("A");
  session.receive("<html>not json</html>");
  session.receive(JSON.stringify({ id: 1, result: { ok: true } }));
  assert.deepEqual(await call, { ok: true });
});

test("events go to their subscribers and stop after unsubscribe", () => {
  const session = createSession(fakeSocket());
  const seen = [];
  const off = session.on("Page.loadEventFired", (params) => seen.push(params));

  session.receive(JSON.stringify({ method: "Page.loadEventFired", params: { timestamp: 1 } }));
  session.receive(JSON.stringify({ method: "Page.somethingElse", params: { timestamp: 2 } }));
  off();
  session.receive(JSON.stringify({ method: "Page.loadEventFired", params: { timestamp: 3 } }));

  assert.deepEqual(seen, [{ timestamp: 1 }]);
});

test("an event with no params still fires", () => {
  const session = createSession(fakeSocket());
  const seen = [];
  session.on("Inspector.detached", (params) => seen.push(params));
  session.receive(JSON.stringify({ method: "Inspector.detached" }));
  assert.deepEqual(seen, [{}]);
});

test("a dead socket fails every outstanding request", async () => {
  const session = createSession(fakeSocket());
  const first = session.send("A");
  const second = session.send("B");

  session.fail(new Error("CDP socket closed"));

  await assert.rejects(first, /CDP socket closed/);
  await assert.rejects(second, /CDP socket closed/);
  assert.equal(session.pendingCount, 0);
  assert.equal(session.isClosed, true);
});

test("sending after close rejects instead of writing to a dead socket", async () => {
  const socket = fakeSocket();
  const session = createSession(socket);
  session.close();

  await assert.rejects(session.send("A"), /CDP session closed/);
  assert.equal(socket.sent.length, 0);
  assert.equal(socket.closed, true);
});

test("close is idempotent and keeps the first failure reason", async () => {
  const session = createSession(fakeSocket());
  session.fail(new Error("socket error"));
  session.close();
  await assert.rejects(session.send("A"), /socket error/);
});

test("a socket that throws on send rejects that request only", async () => {
  const socket = fakeSocket();
  socket.send = () => {
    throw new Error("write after end");
  };
  const session = createSession(socket);

  await assert.rejects(session.send("A"), /write after end/);
  assert.equal(session.pendingCount, 0);
  assert.equal(session.isClosed, false);
});
