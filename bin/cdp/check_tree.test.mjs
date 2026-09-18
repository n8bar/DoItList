// Unit tests for the tree harness's throwaway rule (m04.02 item 7.3.1).
//
// The harness creates one throwaway Initiative in the operator's real account
// and must never leave it behind: it is trashed after a green run, after a
// failed run, and a failure to trash it is said rather than swallowed — while
// the run's own error stays the one reported. One that was never created is
// never trashed. Everything is injected, so this runs with no browser at all.
//
//   docker compose exec -T web node --test "bin/cdp/*.test.mjs"

import assert from "node:assert/strict";
import { test } from "node:test";

import { withThrowaway } from "./check_tree.mjs";

const THROWAWAY = { id: 41, name: "CDP check 1" };

function spyTrash() {
  const trashed = [];
  const trash = async (throwaway) => {
    trashed.push(throwaway.id);
  };
  trash.trashed = trashed;
  return trash;
}

test("a green run trashes the throwaway once and hands back the run's result", async () => {
  const trash = spyTrash();

  const got = await withThrowaway({
    create: async () => THROWAWAY,
    run: async (throwaway) => {
      assert.equal(throwaway, THROWAWAY);
      assert.deepEqual(trash.trashed, [], "the run must see its Initiative untrashed");
      return "8/8";
    },
    trash,
  });

  assert.equal(got, "8/8");
  assert.deepEqual(trash.trashed, [THROWAWAY.id]);
});

test("a failed run still trashes the throwaway, and the run's error is the one thrown", async () => {
  const trash = spyTrash();

  await assert.rejects(
    withThrowaway({
      create: async () => THROWAWAY,
      run: async () => {
        throw new Error("the row waited for the reply");
      },
      trash,
    }),
    /the row waited for the reply/,
  );

  assert.deepEqual(trash.trashed, [THROWAWAY.id]);
});

test("a trash that fails after a failed run is reported as a leak, not hidden", async () => {
  const leaks = [];

  await assert.rejects(
    withThrowaway({
      create: async () => THROWAWAY,
      run: async () => {
        throw new Error("the confirm never opened");
      },
      trash: async () => {
        throw new Error("the session is gone");
      },
      onLeak: (throwaway, cause) => leaks.push(`${throwaway.name}: ${cause.message}`),
    }),
    /the confirm never opened/,
  );

  assert.deepEqual(leaks, ["CDP check 1: the session is gone"]);
});

test("a trash that fails after a green run is the failure", async () => {
  await assert.rejects(
    withThrowaway({
      create: async () => THROWAWAY,
      run: async () => "8/8",
      trash: async () => {
        throw new Error("update initiative answered 403");
      },
    }),
    /update initiative answered 403/,
  );
});

test("a throwaway that could not be created is never trashed and never run in", async () => {
  const trash = spyTrash();

  await assert.rejects(
    withThrowaway({
      create: async () => {
        throw new Error("add initiative answered 401");
      },
      run: async () => assert.fail("the run must not start"),
      trash,
    }),
    /add initiative answered 401/,
  );

  assert.deepEqual(trash.trashed, []);
});

// --- 8.6: the pure halves of the layout, touch and motion checks ---------

import { centredOn, motionOff, shortfalls, touchFloor, uniformWidths } from "./check_tree.mjs";

test("uniformWidths: one width within a pixel is uniform, a ragged stack is not, nothing is not", () => {
  assert.deepEqual(uniformWidths([640, 640, 641]), { uniform: true, min: 640, max: 641 });
  assert.deepEqual(uniformWidths([640, 600, 641]), { uniform: false, min: 600, max: 641 });
  assert.deepEqual(uniformWidths([]), { uniform: false, min: 0, max: 0 });
});

test("motionOff: transition-none takes the property, a zero duration or a nameless animation is off, anything else moves", () => {
  const still = { transitionProperty: "none", transitionDuration: "0.15s", animationName: "none", animationDuration: "0s" };
  assert.equal(motionOff(still), true);
  assert.equal(motionOff({ ...still, transitionProperty: "color, background-color", transitionDuration: "0s, 0s" }), true);
  assert.equal(motionOff({ ...still, transitionProperty: "color", transitionDuration: "0.15s" }), false);
  assert.equal(motionOff({ ...still, animationName: "doit-recompute-pulse", animationDuration: "2s" }), false);
  assert.equal(motionOff({ ...still, animationName: "doit-recompute-pulse", animationDuration: "0s" }), true);
});

test("shortfalls: names each target under the floor in either direction, and nothing when all reach it", () => {
  const measured = [
    { name: "handle", width: 44, height: 44 },
    { name: "chevron", width: 44, height: 24 },
    { name: "New List", width: 94, height: 28 },
  ];
  assert.deepEqual(shortfalls(measured, 44), ["chevron 44×24", "New List 94×28"]);
  assert.deepEqual(shortfalls(measured.slice(0, 1), 44), []);
});

// --- 7.8: the touch layout ---------------------------------------------------

test("touchFloor: 44 with the touch layout on, 24 in the default layout (guardrail 5.1)", () => {
  assert.equal(touchFloor(true), 44);
  assert.equal(touchFloor(false), 24);
});

test("centredOn: within a pixel of the line counts, further does not", () => {
  assert.equal(centredOn(100.4, 100.5), true);
  assert.equal(centredOn(101.5, 100.5), true);
  assert.equal(centredOn(102, 100.5), false);
  assert.equal(centredOn(98, 100.5, 3), true);
});
