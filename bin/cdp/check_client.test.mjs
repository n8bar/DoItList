// Unit tests for the harness's target acquisition and its index sort helper.
//
// The harness drives ONE tab and never closes it (the operator's rule): the
// tab is reused when one is on the app, opened once when none is, and left
// open either way. Everything is injected, so this runs with no browser at all.
//
//   docker compose exec -T web node --test "bin/cdp/*.test.mjs"

import assert from "node:assert/strict";
import { test } from "node:test";

import { acquireSession, indexOrder } from "./check_client.mjs";

const TAB = { id: "tab-1", webSocketDebuggerUrl: "ws://x/1", url: "https://app/app/initiatives" };

test("a successful attach hands back the target and the session", async () => {
  const session = { marker: "live" };

  const got = await acquireSession({
    acquire: async () => TAB,
    attach: async (wsUrl) => {
      assert.equal(wsUrl, TAB.webSocketDebuggerUrl);
      return session;
    },
  });

  assert.equal(got.session, session);
  assert.equal(got.target, TAB);
});

test("a failed attach surfaces the error and leaves the tab alone", async () => {
  await assert.rejects(
    acquireSession({
      acquire: async () => TAB,
      attach: async () => {
        throw new Error("CDP connect timed out after 10000ms");
      },
    }),
    /CDP connect timed out/,
  );
});

test("a failure to acquire never attaches", async () => {
  await assert.rejects(
    acquireSession({
      acquire: async () => {
        throw new Error("could not open a tab");
      },
      attach: async () => assert.fail("attach must not run"),
    }),
    /could not open a tab/,
  );
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
