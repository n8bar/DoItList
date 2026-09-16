import { strict as assert } from "node:assert";
import { test } from "node:test";

import { createApiClient } from "./client.ts";

interface Call {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string | undefined;
}

function stubFetch(responses: Array<{ status: number; body: unknown }>) {
  const calls: Call[] = [];
  const fetchImpl = (async (input: unknown, init: Record<string, unknown> = {}) => {
    const next = responses[calls.length];
    calls.push({
      url: String(input),
      method: String(init["method"] ?? "GET"),
      headers: (init["headers"] ?? {}) as Record<string, string>,
      body: init["body"] as string | undefined,
    });
    if (!next) throw new Error("unexpected extra request");
    return {
      ok: next.status >= 200 && next.status < 300,
      status: next.status,
      json: async () => next.body,
    };
  }) as unknown as typeof fetch;

  return { fetchImpl, calls };
}

const client = (responses: Array<{ status: number; body: unknown }>) => {
  const { fetchImpl, calls } = stubFetch(responses);
  return { api: createApiClient({ csrfToken: "tok", fetchImpl }), calls };
};

test("get unwraps the data envelope", async () => {
  const { api, calls } = client([{ status: 200, body: { data: { hello: "world" } } }]);
  const result = await api.get<{ hello: string }>("/session");

  assert.ok(result.ok);
  assert.deepEqual(result.data, { hello: "world" });
  assert.equal(calls[0]?.url, "/app/api/session");
  assert.equal(calls[0]?.method, "GET");
});

test("a read sends no csrf header and never a bearer token", async () => {
  const { api, calls } = client([{ status: 200, body: { data: {} } }]);
  await api.get("/initiatives");

  const headers = calls[0]?.headers ?? {};
  assert.equal(headers["x-csrf-token"], undefined);
  assert.equal(headers["authorization"], undefined);
  assert.equal(headers["Authorization"], undefined);
});

test("a write sends the csrf header and the JSON body", async () => {
  const { api, calls } = client([{ status: 200, body: { data: { results: [] } } }]);
  await api.post("/operations", { operations: [] });

  assert.equal(calls[0]?.method, "POST");
  assert.equal(calls[0]?.headers["x-csrf-token"], "tok");
  assert.equal(calls[0]?.headers["authorization"], undefined);
  assert.equal(calls[0]?.body, JSON.stringify({ operations: [] }));
});

test("error codes decode into typed errors", async () => {
  for (const [status, code] of [
    [401, "unauthorized"],
    [403, "forbidden"],
    [404, "not_found"],
    [409, "conflict"],
    [422, "unprocessable_entity"],
  ] as const) {
    const { api } = client([{ status, body: { error: { status, code, message: "nope" } } }]);
    const result = await api.get("/initiatives");
    assert.equal(result.ok, false);
    assert.ok(!result.ok);
    assert.equal(result.error.code, code);
    assert.equal(result.error.status, status);
    assert.equal(result.error.message, "nope");
  }
});

test("a stale session refreshes the token and replays the write once", async () => {
  const { api, calls } = client([
    { status: 403, body: { error: { status: 403, code: "stale_session", message: "stale" } } },
    { status: 200, body: { data: { user: null, csrf_token: "fresh" } } },
    { status: 200, body: { data: { ok: true } } },
  ]);

  const result = await api.post<{ ok: boolean }>("/operations", { operations: [] });

  assert.ok(result.ok);
  assert.equal(calls.length, 3);
  assert.equal(calls[1]?.url, "/app/api/session");
  assert.equal(calls[2]?.headers["x-csrf-token"], "fresh");
  assert.equal(api.csrfToken(), "fresh");
});

test("a stale session that stays stale surfaces the error without looping", async () => {
  const stale = {
    status: 403,
    body: { error: { status: 403, code: "stale_session", message: "stale" } },
  };
  const { api, calls } = client([
    stale,
    { status: 200, body: { data: { user: null, csrf_token: "fresh" } } },
    stale,
  ]);

  const result = await api.post("/operations", {});

  assert.ok(!result.ok);
  assert.equal(result.error.code, "stale_session");
  assert.equal(calls.length, 3);
});

test("refreshSession adopts the fresh token", async () => {
  const { api } = client([
    { status: 200, body: { data: { user: { id: 1 }, csrf_token: "newer" } } },
  ]);

  const result = await api.refreshSession();
  assert.ok(result.ok);
  assert.equal(api.csrfToken(), "newer");
});

test("a transport failure is a network error, not a throw", async () => {
  const fetchImpl = (async () => {
    throw new Error("offline");
  }) as unknown as typeof fetch;
  const api = createApiClient({ csrfToken: "tok", fetchImpl });

  const result = await api.get("/session");
  assert.ok(!result.ok);
  assert.equal(result.error.code, "network");
  assert.equal(result.error.message, "offline");
});

test("an unrecognised body is malformed, never silently ok", async () => {
  const { api } = client([{ status: 200, body: { nope: true } }]);
  const ok = await api.get("/session");
  assert.ok(!ok.ok);
  assert.equal(ok.error.code, "malformed");

  const { api: api2 } = client([{ status: 500, body: "<html>" }]);
  const bad = await api2.get("/session");
  assert.ok(!bad.ok);
  assert.equal(bad.error.code, "malformed");
});

test("a rejection carries the body, so a form can place its field errors", async () => {
  const body = {
    error: { status: 422, code: "unprocessable_entity", message: "rolled back" },
    results: [
      {
        index: 0,
        status: "error",
        error: { code: "unprocessable_entity", message: "can't be blank", pointer: "title" },
      },
    ],
  };
  const { api } = client([{ status: 422, body }]);

  const result = await api.post("/operations", {});
  assert.equal(result.ok, false);
  if (result.ok) return;
  assert.deepEqual(result.error.payload, body);
});
