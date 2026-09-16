import { strict as assert } from "node:assert";
import { test } from "node:test";

import { createStartupGuard } from "./startup.ts";

function guard() {
  const failures: string[] = [];
  let readies = 0;
  const g = createStartupGuard({
    onFail: (message) => void failures.push(message),
    onReady: () => void (readies += 1),
  });
  return { g, failures, readyCount: () => readies };
}

test("a startup failure renders recovery and blocks ready", () => {
  const { g, failures, readyCount } = guard();

  g.fail(new Error("boom"));
  assert.deepEqual(failures, ["boom"]);
  assert.equal(g.failed(), true);

  // Nothing may un-fail a failed startup — a late commit must not disarm the
  // watchdog behind a recovery screen.
  g.markReady();
  assert.equal(g.ready(), false);
  assert.equal(readyCount(), 0);
});

test("markReady signals once and disarms the watchdog", () => {
  const { g, readyCount } = guard();

  g.markReady();
  g.markReady();

  assert.equal(g.ready(), true);
  assert.equal(readyCount(), 1);
});

test("a global error after ready is ignored — it is not a startup failure", () => {
  const { g, failures } = guard();

  g.markReady();
  g.fail(new Error("later problem"));

  assert.deepEqual(failures, []);
  assert.equal(g.failed(), false);
});

test("a boundary crash after ready still renders recovery", () => {
  const { g, failures } = guard();

  g.markReady();
  g.crash(new Error("render blew up"));

  // React unmounts the tree on an uncaught error; without this the user is
  // left with an empty #app.
  assert.deepEqual(failures, ["render blew up"]);
  assert.equal(g.failed(), true);
});

test("recovery is rendered at most once", () => {
  const { g, failures } = guard();

  g.fail(new Error("first"));
  g.crash(new Error("second"));
  g.fail(new Error("third"));

  assert.deepEqual(failures, ["first"]);
});

test("a thrown non-Error still produces a sentence", () => {
  const { g, failures } = guard();

  g.crash(null);
  assert.match(failures[0] ?? "", /unexpected error/);
});
