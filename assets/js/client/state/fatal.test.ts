import assert from "node:assert/strict";
import { test } from "node:test";

import { fatalMessage, isFatal, markFatal } from "./fatal.ts";
import { clearFatalError, createRecoveryStore, setFatalError } from "./recovery.ts";

test("a stray rejected promise is not fatal", () => {
  assert.equal(isFatal(new Error("QuotaExceededError")), false);
  assert.equal(isFatal("the cache gave up"), false);
  assert.equal(isFatal(undefined), false);
  assert.equal(isFatal(null), false);
  assert.equal(isFatal({ name: "AbortError" }), false);
});

test("a cross-origin script error carries no error object and is not fatal", () => {
  // window.onerror hands us `event.error === null` for a script from another
  // origin. All we would have is the string "Script error." — never a reason to
  // replace the connection summary.
  assert.equal(isFatal(null), false);
  assert.equal(isFatal("Script error."), false);
});

test("a failure the client marked fatal is fatal", () => {
  const error = markFatal(new Error("The tree state stopped making sense."));

  assert.equal(isFatal(error), true);
  assert.equal(fatalMessage(error), "The tree state stopped making sense.");
});

test("marking returns the same object so it can be thrown inline", () => {
  const error = new Error("boom");
  assert.equal(markFatal(error), error);
});

test("the mark does not show up when the failure is logged or serialised", () => {
  const error = markFatal(new Error("boom"));

  assert.deepEqual(Object.keys(error), []);
  assert.equal(JSON.stringify({ ...error }), "{}");
});

test("a fatal failure with no message still says something a person can read", () => {
  assert.notEqual(fatalMessage(markFatal(new Error(""))), "");
  assert.notEqual(fatalMessage(markFatal({})), "");
});

test("fatalMessage on something that is not fatal is null", () => {
  assert.equal(fatalMessage(new Error("quota")), null);
});

test("the fatal state can be cleared, and the first one still wins until it is", () => {
  const store = createRecoveryStore();

  setFatalError(store, "first");
  setFatalError(store, "second");
  assert.equal(store.get().fatalError, "first");

  clearFatalError(store);
  assert.equal(store.get().fatalError, null);

  setFatalError(store, "third");
  assert.equal(store.get().fatalError, "third");
});

test("clearing when there is nothing to clear keeps the same state object", () => {
  const store = createRecoveryStore();
  const before = store.get();

  clearFatalError(store);
  assert.equal(store.get(), before);
});
