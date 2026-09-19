// Unit tests for the harness's target acquisition (m04.01 item 1.4, fix 1).
//
// Opening a tab and attaching to it are two operations against a REAL browser.
// If the attach fails, the tab we just opened is still sitting in the operator's
// window — so the rule is: a failed attach closes the tab we created, and never
// closes one we merely borrowed. Everything is injected, so this runs with no
// browser at all.
//
//   docker compose exec -T web node --test "bin/cdp/*.test.mjs"

import assert from "node:assert/strict";
import { test } from "node:test";

import { acquireSession, indexOrder } from "./check_client.mjs";

const OUR_TAB = { id: "tab-1", webSocketDebuggerUrl: "ws://x/1", ours: true };
const THEIR_TAB = { id: "tab-9", webSocketDebuggerUrl: "ws://x/9", ours: false };

function spyRelease() {
  const closed = [];
  const release = async (id) => {
    closed.push(id);
  };
  release.closed = closed;
  return release;
}

test("a successful attach hands back the target and the session", async () => {
  const release = spyRelease();
  const session = { marker: "live" };

  const got = await acquireSession({
    acquire: async () => OUR_TAB,
    attach: async (wsUrl) => {
      assert.equal(wsUrl, OUR_TAB.webSocketDebuggerUrl);
      return session;
    },
    release,
  });

  assert.equal(got.session, session);
  assert.equal(got.target, OUR_TAB);
  assert.deepEqual(release.closed, [], "a working session must not close its tab");
});

test("a failed attach closes the tab we opened, exactly once", async () => {
  const release = spyRelease();

  await assert.rejects(
    acquireSession({
      acquire: async () => OUR_TAB,
      attach: async () => {
        throw new Error("CDP connect timed out after 10000ms");
      },
      release,
    }),
    /CDP connect timed out/,
  );

  assert.deepEqual(release.closed, [OUR_TAB.id]);
});

test("a failed attach never closes a tab we only borrowed", async () => {
  const release = spyRelease();

  await assert.rejects(
    acquireSession({
      acquire: async () => THEIR_TAB,
      attach: async () => {
        throw new Error("CDP socket closed before open");
      },
      release,
    }),
    /CDP socket closed/,
  );

  assert.deepEqual(release.closed, [], "the operator's tab is not ours to close");
});

test("the attach error survives a close that also fails", async () => {
  await assert.rejects(
    acquireSession({
      acquire: async () => OUR_TAB,
      attach: async () => {
        throw new Error("handshake refused");
      },
      release: async () => {
        throw new Error("close failed too");
      },
    }),
    /handshake refused/,
  );
});

test("a failure to acquire never calls release", async () => {
  const release = spyRelease();

  await assert.rejects(
    acquireSession({
      acquire: async () => {
        throw new Error("could not open a tab");
      },
      attach: async () => assert.fail("attach must not run"),
      release,
    }),
    /could not open a tab/,
  );

  assert.deepEqual(release.closed, []);
});

// --- indexOrder (item 8.14): the index's sort, for the rows a check seeded ---

const ROWS = [
  { id: 1, name: "b", progress: 75, created_at: "2026-09-18T01:00:00Z", updated_at: "2026-09-18T03:00:00Z", sort_order: null },
  { id: 2, name: "C", progress: 25, created_at: "2026-09-18T02:00:00Z", updated_at: "2026-09-18T02:00:00Z", sort_order: 0 },
  { id: 3, name: "a", progress: 0, created_at: "2026-09-18T03:00:00Z", updated_at: "2026-09-18T01:00:00Z", sort_order: null },
];

test("Recent keeps the server's order; Reverse flips it", () => {
  assert.deepEqual(indexOrder(ROWS, ""), [1, 2, 3]);
  assert.deepEqual(indexOrder(ROWS, "", true), [3, 2, 1]);
});

test("each keyed mode sorts ascending, names without regard to case", () => {
  assert.deepEqual(indexOrder(ROWS, "name"), [3, 1, 2]);
  assert.deepEqual(indexOrder(ROWS, "progress"), [3, 2, 1]);
  assert.deepEqual(indexOrder(ROWS, "created"), [1, 2, 3]);
  assert.deepEqual(indexOrder(ROWS, "updated"), [3, 2, 1]);
  assert.deepEqual(indexOrder(ROWS, "name", true), [2, 1, 3]);
});

test("Manual puts placed rows first by slot and the unplaced after, in server order", () => {
  assert.deepEqual(indexOrder(ROWS, "manual"), [2, 1, 3]);
  const placed = ROWS.map((row) => ({ ...row, sort_order: row.id === 3 ? 0 : row.id === 1 ? 1 : 2 }));
  assert.deepEqual(indexOrder(placed, "manual"), [3, 1, 2]);
});

test("ties keep server order and the input is left alone", () => {
  const tied = ROWS.map((row) => ({ ...row, progress: 50 }));
  assert.deepEqual(indexOrder(tied, "progress"), [1, 2, 3]);
  assert.deepEqual(ROWS.map((row) => row.id), [1, 2, 3]);
});
