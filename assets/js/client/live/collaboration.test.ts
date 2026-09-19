// Two clients, one server, conflicting intent (m04.03 items 6.3, 6.5).
//
// Each client is the real stack the screen wires: a sync session over its
// own domain store, and an operation adapter whose predictions go through the
// session (`onSubmit` → `begin`, `onResult` → `succeed` / `reject`). The
// server is `fake_server.ts`. Every scenario ends the same way: once every
// envelope is delivered, both clients' canonical trees are deep-equal to the
// server's — whichever order replies and broadcasts reached them in.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient } from "../api/client.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore } from "../state/ui.ts";
import type { SubmitResult, TreeWrite } from "../tree/adapter.ts";
import { createAdapter, predictWrite } from "../tree/adapter.ts";
import { buildTree } from "../tree/gen.ts";
import type { TreeModel } from "../tree/model.ts";
import type { FakeServer, ServerClient } from "./fake_server.ts";
import { fakeServer } from "./fake_server.ts";
import { fakeTimers } from "./fake_transport.ts";
import { createInitiativeSync } from "./refresh.ts";

const ID = 12;

// root 1 ─ 10 ─ 11
//        │    ├ 12
//        │    └ 13
//        ├ 20 ─ 21
//        └ 30
const start = () =>
  buildTree(
    [
      { id: 10, children: [{ id: 11 }, { id: 12 }, { id: 13 }] },
      { id: 20, children: [{ id: 21 }] },
      { id: 30 },
    ],
    { id: ID, seq: 1 },
  );

/** Enough turns of the microtask queue for a chained send and its reply. */
const flush = async (): Promise<void> => {
  for (let i = 0; i < 12; i += 1) await new Promise((resolve) => setTimeout(resolve, 0));
};

function client(server: FakeServer, name: string, userId: number) {
  const domain = createDomainStore();
  const clock = fakeTimers();
  const handle: ServerClient = server.client(name, userId);
  const sync = createInitiativeSync({
    api: handle.api as unknown as ApiClient,
    domain,
    ui: createUiStore(),
    onForbidden: () => {},
    timers: clock.timers,
  });
  sync.install(server.snapshot());

  let n = 0;
  const results: Array<{ key: string; result: SubmitResult }> = [];
  const context = (model: TreeModel | undefined) => (model === undefined ? undefined : { model, memberIds: [] });
  const adapter = createAdapter({
    api: handle.api,
    context: (initiativeId) => context(domain.get().trees[initiativeId]),
    sendContext: (initiativeId) => context(sync.canonical(initiativeId)),
    keyGen: () => `${name}-${++n}`,
    // The screen's `beginFlight`, without the marks.
    onSubmit: ({ initiativeId, key, write }) => {
      const tempId = write?.kind === "add" ? -1 : null;
      sync.begin(initiativeId, {
        key,
        predict: (base) => (write === null ? base : (predictWrite(write, { model: base }, -1) ?? base)),
        tempId,
      });
    },
    onResult: ({ initiativeId, key }, result) => {
      results.push({ key, result });
      if (result.ok) sync.succeed(initiativeId, key, result.delta, result.seq);
      else sync.reject(initiativeId, key);
    },
  });

  return {
    name,
    handle,
    sync,
    adapter,
    clock,
    results,
    shown: () => domain.get().trees[ID] as TreeModel,
    canonical: () => sync.canonical(ID) as TreeModel,
    submit: (write: TreeWrite) => void adapter.submit(ID, write),
    /** Every envelope waiting for this client, in order. */
    deliver: () => {
      const due = handle.inbox.splice(0, handle.inbox.length);
      for (const envelope of due) sync.onDelta(envelope);
    },
  };
}

type Client = ReturnType<typeof client>;

/** Both clients level with the server: the same records, the same order, the same header, the same sequence. */
function assertConverged(server: FakeServer, ...clients: Client[]): void {
  const truth = server.canonical();
  for (const c of clients) {
    const model = c.canonical();
    assert.deepEqual(model.tasks, truth.tasks, `${c.name}: records`);
    assert.deepEqual(model.childIds, truth.childIds, `${c.name}: order`);
    assert.deepEqual(model.header, truth.header, `${c.name}: header`);
    assert.equal(model.seq, truth.seq, `${c.name}: sequence`);
    assert.equal(c.sync.flights(ID).length, 0, `${c.name}: nothing left in flight`);
    assert.deepEqual(c.shown(), model, `${c.name}: what is shown is truth`);
  }
}

/** Sends everything, then delivers every inbox until they are all empty. */
async function settle(...clients: Client[]): Promise<void> {
  for (let round = 0; round < 6; round += 1) {
    await flush();
    for (const c of clients) c.deliver();
  }
}

type EditFields = Extract<TreeWrite, { kind: "edit" }>["fields"];
const edit = (id: number, fields: EditFields): TreeWrite => ({ kind: "edit", id, fields });

describe("same-field and different-field edits (6.3.1)", () => {
  it("two edits to one field: the second is rebased onto the first's version, and both clients end on the server's answer", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    a.submit(edit(11, { title: "Ada's title" }));
    b.submit(edit(11, { title: "Bo's title" }));
    // §6.7: each prediction is on its own screen before anything was awaited.
    assert.equal(a.shown().tasks[11]?.title, "Ada's title");
    assert.equal(b.shown().tasks[11]?.title, "Bo's title");

    await settle(a, b);

    assert.equal(server.canonical().tasks[11]?.title, "Bo's title", "last writer, at the right version");
    assert.equal(server.canonical().tasks[11]?.version, 3);
    assert.deepEqual(
      b.handle.posts.map((post) => post.body.operations[0]?.data["expected_version"]),
      [1, 2],
      "Bo's stale send, then the rebase onto the version the conflict named",
    );
    assert.notEqual(b.handle.posts[0]?.key, b.handle.posts[1]?.key, "the rebase is a new request");
    assertConverged(server, a, b);
  });

  it("edits to different fields of one record: the rebase carries the user's field only, so the other survives (6.5)", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    a.submit(edit(11, { title: "Ada's title" }));
    b.submit(edit(11, { description: "Bo's notes" }));
    await settle(a, b);

    const record = server.canonical().tasks[11];
    assert.equal(record?.title, "Ada's title", "the field Bo never touched is Ada's");
    assert.equal(record?.description, "Bo's notes");
    assert.deepEqual(Object.keys(b.handle.posts[1]?.body.operations[0]?.data ?? {}).sort(), ["description", "expected_version"]);
    assertConverged(server, a, b);
  });

  it("converges whichever way each client's reply and broadcast are ordered", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);
    // Ada's reply is held: her own broadcast reaches her first, and settles the write.
    a.handle.holdReplies();

    a.submit(edit(12, { title: "Ada's" }));
    b.submit(edit(12, { priority: "high" }));
    await flush();
    a.deliver();
    assert.equal(a.sync.flights(ID).length, 0, "the broadcast settled Ada's write");
    assert.equal(a.canonical().tasks[12]?.title, "Ada's");

    a.handle.releaseReplies();
    await settle(a, b);
    assert.equal(server.canonical().tasks[12]?.title, "Ada's");
    assert.equal(server.canonical().tasks[12]?.priority, "high");
    assertConverged(server, a, b);
  });
});

describe("completion and delete/edit conflicts (6.3.2)", () => {
  it("a completion and an edit of the same task both land", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    a.submit({ kind: "toggleComplete", id: 11, done: true });
    b.submit(edit(11, { title: "Renamed while completing" }));
    await settle(a, b);

    const record = server.canonical().tasks[11];
    assert.equal(record?.done, true);
    assert.equal(record?.title, "Renamed while completing");
    assert.equal(server.canonical().tasks[10]?.progress, Math.round(100 / 3), "the roll-up reached the parent");
    assertConverged(server, a, b);
  });

  it("an edit of a task someone else deleted is refused, kept for the user, and the row goes when the delete arrives", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    a.submit({ kind: "delete", id: 21 });
    b.submit(edit(21, { title: "Too late" }));
    assert.equal(b.shown().tasks[21]?.title, "Too late", "predicted at once");
    await flush();

    const refused = b.results.find((entry) => entry.key === "Bo-1")?.result;
    assert.ok(refused !== undefined && !refused.ok);
    assert.equal(refused.error.code, "not_found");
    assert.equal(refused.recoverable, true, "an edit whose row is still on this screen is the user's to Retry or Discard");
    assert.equal(b.shown().tasks[21]?.title, "Task 21", "the prediction is reverted to truth");

    await settle(a, b);
    assert.equal(server.canonical().tasks[21], undefined);
    assert.equal(b.canonical().tasks[21], undefined);
    assertConverged(server, a, b);
  });
});

describe("structural conflicts (6.3.3)", () => {
  it("a move under a parent someone else deleted: sent before the delete is known, it is refused and reverted", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    a.submit({ kind: "delete", id: 20 });
    b.submit({ kind: "move", id: 11, parentId: 20, position: 0, reorder: false });
    assert.deepEqual(b.shown().childIds[20], [11, 21], "predicted at once");
    await flush();

    const refused = b.results.find((entry) => entry.key === "Bo-1")?.result;
    assert.ok(refused !== undefined && !refused.ok);
    assert.equal(refused.error.code, "not_found");
    assert.equal(refused.recoverable, false, "structural optimism is simply reverted");

    await settle(a, b);
    assert.deepEqual(server.canonical().childIds[10], [11, 12, 13]);
    assertConverged(server, a, b);
  });

  it("a move under a parent someone else deleted: built after the delete is known, it is refused without a request", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    // Bo's move waits behind an edit whose reply is held back.
    b.handle.holdReplies();
    b.submit(edit(30, { title: "First" }));
    b.submit({ kind: "move", id: 11, parentId: 20, position: 0, reorder: false });
    await flush();
    assert.equal(b.handle.posts.length, 1, "the move is queued, not sent");

    a.submit({ kind: "delete", id: 20 });
    await flush();
    b.deliver();
    assert.equal(b.canonical().tasks[20], undefined, "Bo knows the parent is gone");

    b.handle.releaseReplies();
    await settle(a, b);
    assert.equal(b.handle.posts.length, 1, "the move never went out");
    const refused = b.results.find((entry) => entry.key === "Bo-2")?.result;
    assert.ok(refused !== undefined && !refused.ok);
    assert.equal(refused.error.code, "conflict");
    assertConverged(server, a, b);
  });

  it("a reorder beside a sibling someone else moved away: the anchor is re-read, the row lands at the end, and the lists agree", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    // Ada moves 12 out from under 10; Bo drops 11 just after 12.
    b.handle.holdReplies();
    b.submit(edit(30, { title: "First" }));
    b.submit({ kind: "move", id: 11, parentId: 10, position: 1, reorder: true, anchor: { id: 12, side: "after" } });
    assert.deepEqual(b.shown().childIds[10], [12, 11, 13], "predicted against the list as it stood");
    await flush();

    a.submit({ kind: "move", id: 12, parentId: 20, position: null, reorder: false });
    await flush();
    b.deliver();

    b.handle.releaseReplies();
    await settle(a, b);
    assert.deepEqual(server.canonical().childIds[10], [13, 11], "after 12 became: at the end");
    assert.deepEqual(server.canonical().childIds[20], [12, 21]);
    assert.equal(b.handle.posts[1]?.body.operations[0]?.data["position"], undefined, "a lost anchor sends no slot");
    assertConverged(server, a, b);
  });

  it("the same drop sent before the sibling's move is known clamps on the server, and still converges", async () => {
    const server = fakeServer(start());
    const a = client(server, "Ada", 1);
    const b = client(server, "Bo", 2);

    a.submit({ kind: "move", id: 12, parentId: 20, position: null, reorder: false });
    b.submit({ kind: "move", id: 11, parentId: 10, position: 1, reorder: true, anchor: { id: 12, side: "after" } });
    await settle(a, b);

    assert.deepEqual(server.canonical().childIds[10], [13, 11]);
    assertConverged(server, a, b);
  });
});

describe("the fake server itself", () => {
  it("replays a stored response for the same key and bytes, and refuses the same key with other bytes", async () => {
    const server = fakeServer(start());
    const handle = server.client("Ada", 1);
    const body = { operations: [{ op: "update", type: "task", id: 30, data: { title: "Once" } }] };
    const first = await handle.api.post("/operations", body, { "idempotency-key": "k" });
    const again = await handle.api.post("/operations", body, { "idempotency-key": "k" });
    assert.deepEqual(again, first);
    assert.equal(server.seq(), 2, "committed once");
    assert.equal(handle.inbox.length, 1, "one envelope");

    const other = await handle.api.post(
      "/operations",
      { operations: [{ op: "update", type: "task", id: 30, data: { title: "Twice" } }] },
      { "idempotency-key": "k" },
    );
    assert.equal(other.ok, false);
    assert.equal(server.canonical().tasks[30]?.title, "Once");
  });
});
