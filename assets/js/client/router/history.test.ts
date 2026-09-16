import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { HistoryEntry, HistoryEnv, HistoryLike } from "./history.ts";
import { createClientHistory, keyOf, stateWithKey } from "./history.ts";

/** A fake browser history: a stack, a pathname, and a popstate we can fire. */
function fakeEnv(startPath = "/app/initiatives", startState: unknown = null) {
  let pathname = startPath;
  const stack: { path: string; state: unknown }[] = [{ path: startPath, state: startState }];
  let index = 0;
  const listeners: ((state: unknown) => void)[] = [];

  const history: HistoryLike = {
    get state() {
      return stack[index]?.state ?? null;
    },
    pushState(state, _unused, url) {
      stack.length = index + 1;
      stack.push({ path: url, state });
      index += 1;
      pathname = url;
    },
    replaceState(state, _unused, url) {
      stack[index] = { path: url, state };
      pathname = url;
    },
    scrollRestoration: "auto",
  };

  const env: HistoryEnv = {
    history,
    location: {
      get pathname() {
        return pathname;
      },
    },
    addPopStateListener(listener) {
      listeners.push(listener);
      return () => {
        const at = listeners.indexOf(listener);
        if (at >= 0) listeners.splice(at, 1);
      };
    },
    makeKey: (() => {
      let n = 0;
      return () => {
        n += 1;
        return `key-${n}`;
      };
    })(),
  };

  const go = (delta: number) => {
    const next = index + delta;
    if (next < 0 || next >= stack.length) return;
    index = next;
    pathname = stack[index]?.path ?? "/";
    const state = stack[index]?.state ?? null;
    for (const listener of [...listeners]) listener(state);
  };

  return { env, history, go, stack: () => stack.map((e) => e.path), index: () => index };
}

describe("history state keys", () => {
  it("reads our key back and ignores foreign state", () => {
    assert.equal(keyOf({ doitKey: "k1" }), "k1");
    assert.equal(keyOf({ other: 1 }), null);
    assert.equal(keyOf(null), null);
    assert.equal(keyOf("k1"), null);
    assert.equal(keyOf({ doitKey: "" }), null);
  });

  it("preserves anything already on the state object", () => {
    assert.deepEqual(stateWithKey({ phx: 1 }, "k1"), { phx: 1, doitKey: "k1" });
    assert.deepEqual(stateWithKey(null, "k1"), { doitKey: "k1" });
  });
});

describe("createClientHistory", () => {
  it("takes over scroll restoration", () => {
    const { env, history } = fakeEnv();
    createClientHistory(env);
    assert.equal(history.scrollRestoration, "manual");
  });

  it("stamps the entry the page loaded on", () => {
    const { env, history } = fakeEnv("/app/initiatives/42");
    const client = createClientHistory(env);
    assert.deepEqual(client.current(), {
      path: "/app/initiatives/42",
      key: "key-1",
      kind: "initial",
    });
    assert.equal(keyOf(history.state), "key-1");
  });

  it("adopts the key a refresh left behind rather than minting a new one", () => {
    // What a reload looks like: same URL, and the history state we wrote before.
    const { env } = fakeEnv("/app/account", { doitKey: "k-before-reload" });
    const client = createClientHistory(env);
    assert.equal(client.current().key, "k-before-reload");
  });

  it("pushes a new entry with a new key and notifies", () => {
    const { env, stack } = fakeEnv();
    const client = createClientHistory(env);
    const seen: HistoryEntry[] = [];
    client.listen((entry) => seen.push(entry));

    client.push("/app/initiatives/42");

    assert.deepEqual(stack(), ["/app/initiatives", "/app/initiatives/42"]);
    assert.deepEqual(seen, [{ path: "/app/initiatives/42", key: "key-2", kind: "push" }]);
    assert.equal(client.current().path, "/app/initiatives/42");
  });

  it("replaces without growing the stack, and with a fresh key", () => {
    const { env, stack } = fakeEnv("/app");
    const client = createClientHistory(env);
    const before = client.current().key;

    client.replace("/app/initiatives");

    assert.deepEqual(stack(), ["/app/initiatives"]);
    assert.equal(client.current().path, "/app/initiatives");
    assert.notEqual(client.current().key, before);
  });

  it("restores the entry's own key on back and forward", () => {
    const { env, go } = fakeEnv();
    const client = createClientHistory(env);
    const first = client.current().key;

    client.push("/app/initiatives/42");
    const second = client.current().key;

    const seen: HistoryEntry[] = [];
    client.listen((entry) => seen.push(entry));

    go(-1);
    assert.deepEqual(client.current(), { path: "/app/initiatives", key: first, kind: "pop" });

    go(1);
    assert.deepEqual(client.current(), { path: "/app/initiatives/42", key: second, kind: "pop" });

    assert.deepEqual(
      seen.map((e) => e.kind),
      ["pop", "pop"],
    );
  });

  it("gives the same entry the same key on every visit, and two visits different keys", () => {
    const { env, go } = fakeEnv();
    const client = createClientHistory(env);

    client.push("/app/initiatives/42");
    const firstVisit = client.current().key;
    go(-1);
    client.push("/app/initiatives/42");
    const secondVisit = client.current().key;

    assert.notEqual(firstVisit, secondVisit, "two visits to one path are two entries");
  });

  it("stops notifying after dispose", () => {
    const { env, go } = fakeEnv();
    const client = createClientHistory(env);
    client.push("/app/account");

    let calls = 0;
    client.listen(() => {
      calls += 1;
    });
    client.dispose();
    go(-1);

    assert.equal(calls, 0);
  });
});
