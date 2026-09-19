import { strict as assert } from "node:assert";
import { test } from "node:test";

import { identityMismatch, initialState, loginPath, parseBootstrap, stateForErrorCode } from "./boot.ts";

const payload = (overrides: Record<string, unknown> = {}) =>
  JSON.stringify({
    user: { id: 7, email: "a@example.com", username: "ann", name: "Ann" },
    csrf_token: "tok",
    path: "/app/initiatives/3",
    ...overrides,
  });

test("parseBootstrap reads a signed-in payload", () => {
  const result = parseBootstrap(payload());
  assert.ok(result.ok);
  assert.deepEqual(result.bootstrap.user, {
    id: 7,
    email: "a@example.com",
    username: "ann",
    name: "Ann",
  });
  assert.equal(result.bootstrap.csrfToken, "tok");
  assert.equal(result.bootstrap.path, "/app/initiatives/3");
});

test("parseBootstrap reads a signed-out payload", () => {
  const result = parseBootstrap(payload({ user: null }));
  assert.ok(result.ok);
  assert.equal(result.bootstrap.user, null);
});

test("parseBootstrap keeps a null name", () => {
  const result = parseBootstrap(
    payload({ user: { id: 1, email: "b@example.com", username: "bo", name: null } }),
  );
  assert.ok(result.ok);
  assert.equal(result.bootstrap.user?.name, null);
});

test("parseBootstrap defaults a missing path", () => {
  const result = parseBootstrap(payload({ path: undefined }));
  assert.ok(result.ok);
  assert.equal(result.bootstrap.path, "/app");
});

test("parseBootstrap rejects missing, blank, and non-JSON input", () => {
  for (const raw of [null, undefined, "", "   ", "not json"]) {
    const result = parseBootstrap(raw);
    assert.equal(result.ok, false);
  }
});

test("parseBootstrap rejects a payload with no csrf token", () => {
  const result = parseBootstrap(payload({ csrf_token: "" }));
  assert.equal(result.ok, false);
});

test("parseBootstrap rejects an unreadable user", () => {
  const result = parseBootstrap(payload({ user: { id: "seven" } }));
  assert.equal(result.ok, false);
});

test("initialState is ready when a user is present", () => {
  const result = parseBootstrap(payload());
  assert.deepEqual(initialState(result), {
    kind: "ready",
    user: { id: 7, email: "a@example.com", username: "ann", name: "Ann" },
  });
});

test("initialState is signed-out with a null user", () => {
  assert.deepEqual(initialState(parseBootstrap(payload({ user: null }))), { kind: "signed-out" });
});

test("initialState is start-failed on a bad payload", () => {
  const state = initialState(parseBootstrap("nope"));
  assert.equal(state.kind, "start-failed");
});

test("stateForErrorCode maps the session codes", () => {
  assert.deepEqual(stateForErrorCode("unauthorized"), { kind: "signed-out" });
  assert.deepEqual(stateForErrorCode("forbidden"), { kind: "forbidden" });
  assert.deepEqual(stateForErrorCode("network", "offline"), {
    kind: "start-failed",
    message: "offline",
  });
  // Recoverable or call-specific — the caller handles these in place.
  assert.equal(stateForErrorCode("stale_session"), null);
  assert.equal(stateForErrorCode("conflict"), null);
  assert.equal(stateForErrorCode("not_found"), null);
});

test("loginPath returns the user to where they were", () => {
  assert.equal(loginPath("/app/initiatives/3"), "/users/log_in?return_to=%2Fapp%2Finitiatives%2F3");
  assert.equal(loginPath(""), "/users/log_in?return_to=%2Fapp");
});

test("a session read that names another account is unrecoverable (m04.03 5.1.2)", () => {
  const me = { id: 7, email: "me@example.com", username: "me", name: null };
  assert.equal(identityMismatch(me, { id: 7 }), null);
  assert.equal(identityMismatch(null, { id: 7 }), null);
  assert.match(String(identityMismatch(me, { id: 8 })), /Reload/);
});
