// Offline edit → the tab dies → a new tab → the server is back (m04.03 6.2.1).
//
// Two "tabs" over one fake IndexedDB, each with fresh stores, a fresh sync
// session and a fresh adapter — wired the way the screen wires them. The first
// tab queues two writes while the link is down: one gets out and loses its
// reply (`sent`), the next waits behind it (`queued`). The tab is then dropped
// without any tidy-up. The second tab paints the device's copy, waits for the
// server's own snapshot, and only then replays both records in creation order
// — the sent one byte for byte under its own key, the queued one built from
// truth as the snapshot left it — and the journal ends empty.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore } from "../state/ui.ts";
import type { BatchReply, Operation, TreeWrite } from "../tree/adapter.ts";
import { createAdapter, predictWrite } from "../tree/adapter.ts";
import { buildTree } from "../tree/gen.ts";
import type { TreeModel } from "../tree/model.ts";
import { fromSnapshot } from "../tree/model.ts";
import { fakeTimers } from "../live/fake_transport.ts";
import { createInitiativeSync } from "../live/refresh.ts";
import { openClientCache } from "./client_cache.ts";
import { FakeIdb } from "./fake_idb.ts";
import type { KeyValueStore } from "./last_user.ts";
import type { PendingOp } from "./pending_ops.ts";
import { replayPlan } from "./pending_ops.ts";

const USER = 41;
const ID = 12;

const fakeStore = (): KeyValueStore => {
  const map = new Map<string, string>();
  return {
    getItem: (key) => map.get(key) ?? null,
    setItem: (key, value) => void map.set(key, value),
    removeItem: (key) => void map.delete(key),
  };
};

// root 1 ─ 10
//        └ 11
const treeAt = (seq: number) => buildTree([{ id: 10 }, { id: 11 }], { id: ID, seq });

const flush = async (): Promise<void> => {
  for (let i = 0; i < 10; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

interface Post {
  key: string;
  body: { operations: Operation[] };
  resolve: (value: Result<BatchReply>) => void;
}

/** A `post` the test answers by hand; `offline` answers every call with a network error. */
function fakeApi() {
  const posts: Post[] = [];
  let offline = false;
  const api = {
    post: <T,>(_path: string, body: unknown, headers?: Record<string, string>): Promise<Result<T>> => {
      if (offline) {
        return Promise.resolve({ ok: false, error: { code: "network", status: 0, message: "Failed to fetch" } });
      }
      return new Promise<Result<T>>((resolve) => {
        posts.push({
          key: headers?.["idempotency-key"] ?? "",
          body: body as { operations: Operation[] },
          resolve: resolve as (value: Result<BatchReply>) => void,
        });
      });
    },
    get: () => Promise.reject(new Error("not used")),
  } as unknown as ApiClient;
  return {
    api,
    posts,
    goOffline: () => {
      offline = true;
    },
  };
}

/** One life of the tab: fresh stores over the shared IndexedDB. */
function tab(idb: FakeIdb, name: string) {
  const domain = createDomainStore();
  const clock = fakeTimers();
  const fake = fakeApi();
  const cache = openClientCache({ userId: USER, idb, keyValue: fakeStore() });
  const sync = createInitiativeSync({
    api: fake.api,
    domain,
    ui: createUiStore(),
    onForbidden: () => {},
    timers: clock.timers,
    snapshots: cache,
  });

  let n = 0;
  const unknown: string[] = [];
  const results: string[] = [];
  const context = (model: TreeModel | undefined) => (model === undefined ? undefined : { model, memberIds: [] });
  const begin = (key: string, write: TreeWrite | null): void => {
    if (sync.flights(ID).includes(key)) return;
    sync.begin(ID, {
      key,
      predict: (base) => (write === null ? base : (predictWrite(write, { model: base }, -1) ?? base)),
      tempId: null,
    });
  };
  const adapter = createAdapter({
    api: fake.api,
    context: (initiativeId) => context(domain.get().trees[initiativeId]),
    sendContext: (initiativeId) => context(sync.canonical(initiativeId)),
    keyGen: () => `${name}-${++n}`,
    now: () => 1000 + n,
    journal: { put: (record) => cache.putPendingOp(record), remove: (key) => cache.deletePendingOp(key) },
    onSubmit: ({ key, write }) => begin(key, write),
    onResult: ({ key }, result) => {
      results.push(`${key}:${result.ok ? "ok" : result.error.code}`);
      if (result.ok) sync.succeed(ID, key, result.delta, result.seq);
      else sync.reject(ID, key);
    },
    onUnknown: ({ key }) => unknown.push(key),
  });

  /** The screen's `replay`: drawn as unsaved in the same step, then sent again. */
  const replay = (record: PendingOp): void => {
    begin(record.key, record.payload.kind === "write" ? record.payload.write : null);
    void adapter.resubmit(record);
  };

  return {
    domain,
    clock,
    fake,
    cache,
    sync,
    adapter,
    unknown,
    results,
    replay,
    shown: () => domain.get().trees[ID] as TreeModel,
  };
}

const okReply = (id: number, version: number): Result<BatchReply> => ({
  ok: true,
  data: {
    results: [
      {
        index: 0,
        status: "ok",
        data: {
          id,
          type: "task",
          title: id === 10 ? "Renamed offline" : `Task ${id}`,
          parent_id: 1,
          status: id === 11 ? "done" : "open",
          done: id === 11,
          progress: id === 11 ? 100 : 0,
          manual_progress: id === 11 ? 100 : 0,
          priority: "normal",
          assignee_id: null,
          version,
        },
      },
    ],
    seq: { [String(ID)]: 3 },
  },
});

describe("offline edit → reload → reconnect (m04.03 6.2.1)", () => {
  it("both records survive the tab, replay in order after the server snapshot, and the journal ends empty", async () => {
    const idb = new FakeIdb();

    // --- the first life: online long enough to read, then the link goes ----
    const first = tab(idb, "one");
    await first.cache.ready;
    first.sync.install(treeAt(1));
    first.clock.flush(); // the snapshot-cache debounce: the device's copy is written
    await flush();
    assert.equal((await first.cache.readTree(ID))?.seq, 1, "the device holds the tree");

    first.fake.goOffline();
    void first.adapter.submit(ID, { kind: "toggleComplete", id: 11, done: true });
    void first.adapter.submit(ID, { kind: "edit", id: 10, fields: { title: "Renamed offline" } });
    // §6.7: both predictions are on screen in the same step as they were queued.
    assert.equal(first.shown().tasks[11]?.done, true);
    assert.equal(first.shown().tasks[10]?.title, "Renamed offline");
    await flush();

    assert.deepEqual(first.unknown, ["one-1"], "the first went out and lost its reply; the second waits behind it");
    const kept = await first.cache.pendingOps();
    assert.deepEqual(
      kept.map((record) => [record.key, record.payload.status]),
      [
        ["one-1", "sent"],
        ["one-2", "queued"],
      ],
    );
    const sentBody = kept[0]?.payload.body;
    assert.ok(sentBody !== null && sentBody !== undefined, "the sent record keeps its bytes");

    // The tab dies here: no close, no purge, nothing awaited.
    first.cache.close();

    // --- the second life -------------------------------------------------
    const second = tab(idb, "two");
    await second.cache.ready;
    const records = await second.cache.pendingOps();
    assert.deepEqual(records.map((record) => record.key), ["one-1", "one-2"], "both came back from the device");

    // The device's copy paints first, with the pending work drawn on it.
    const cached = await second.cache.readTree(ID);
    assert.ok(cached !== null);
    assert.equal(second.sync.installCached(cached), true);
    second.adapter.hold(ID);
    for (const record of replayPlan(records, ID)) second.replay(record);
    assert.equal(second.shown().tasks[11]?.done, true, "drawn as unsaved before anything is sent");
    assert.equal(second.shown().tasks[10]?.title, "Renamed offline");
    await flush();
    assert.equal(second.fake.posts.length, 1, "the sent record goes again at once");
    assert.equal(second.fake.posts[0]?.key, "one-1", "under its own key");
    assert.deepEqual(second.fake.posts[0]?.body, sentBody, "byte for byte");

    // The server's snapshot lands (someone else edited meanwhile: seq 2, task 10 at version 2).
    const snapshot = treeAt(2);
    (snapshot.tasks[0] as { version: number }).version = 2;
    second.sync.install(snapshot);
    second.adapter.open(ID);
    second.adapter.resume(ID);

    second.fake.posts[0]?.resolve(okReply(11, 2));
    await flush();
    assert.equal(second.fake.posts.length, 2, "the queued record follows, in creation order");
    assert.equal(second.fake.posts[1]?.key, "one-2");
    assert.deepEqual(
      second.fake.posts[1]?.body.operations[0]?.data,
      { title: "Renamed offline", expected_version: 2 },
      "built from truth as the snapshot left it, not from the tab that died",
    );

    second.fake.posts[1]?.resolve(okReply(10, 3));
    await flush();
    assert.deepEqual(second.results, ["one-1:ok", "one-2:ok"]);
    assert.deepEqual(await second.cache.pendingOps(), [], "the journal is empty");
    assert.equal(second.sync.flights(ID).length, 0);
    assert.equal(second.shown().tasks[10]?.title, "Renamed offline");
    assert.equal(second.shown().tasks[11]?.done, true);
    second.cache.close();
  });
});
