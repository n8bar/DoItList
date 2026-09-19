// The socket comes back: every joined Initiative resyncs from its own sequence
// (m04.03 3.3). The connection and the sync are wired together here, as
// `app.tsx` wires them, and driven through the fake socket's rejoin.

import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import type { InitiativeTree } from "../api/types.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore } from "../state/ui.ts";
import { buildTree } from "../tree/gen.ts";
import { fromSnapshot } from "../tree/model.ts";
import { createConnection } from "./connection.ts";
import { envelope, record } from "./fake_envelope.ts";
import { fakeTimers, fakeTransport } from "./fake_transport.ts";
import { createInitiativeSync } from "./refresh.ts";

/** Initiative `id` at `seq`, with one top-level task `id*10+1`. */
const treeWith = (id: number, seq: number, title = "Original") =>
  buildTree([{ id: id * 10 + 1, title }], { id, name: "Kitchen", rootTaskId: id * 10, seq });

const retitle = (id: number, seq: number, title: string) => ({
  ...envelope(seq, { upserts: [record(id * 10 + 1, id * 10, 0, { title, version: 2 })] }),
  initiativeId: id,
});

/** Reads that answer from a table, or park until released. */
function fakeApi() {
  const answers = new Map<string, InitiativeTree>();
  const calls: string[] = [];
  const parked: Array<() => void> = [];
  let holding = false;
  const api = {
    get: <T,>(path: string): Promise<Result<T>> => {
      calls.push(path);
      const respond = (): Result<T> => {
        const data = answers.get(path);
        return data === undefined
          ? { ok: false, error: { code: "not_found", status: 404, message: "gone" } }
          : { ok: true, data: data as T };
      };
      if (!holding) return Promise.resolve(respond());
      return new Promise<Result<T>>((resolve) => parked.push(() => resolve(respond())));
    },
    post: () => Promise.reject(new Error("not used")),
    refreshSession: () => Promise.reject(new Error("not used")),
    csrfToken: () => "token",
  } as unknown as ApiClient;
  return {
    api,
    calls,
    answer: (id: number, tree: InitiativeTree) => answers.set(`/initiatives/${id}`, tree),
    hold: () => {
      holding = true;
    },
    release: (index: number) => parked[index]?.(),
    parked: () => parked.length,
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

/** The two units, wired as the app wires them, over a live fake socket. */
function harness() {
  const socket = fakeTransport();
  const clock = fakeTimers();
  const fake = fakeApi();
  const domain = createDomainStore();
  const synced: number[] = [];

  // Built the way `app.tsx` builds them: the sync first, reaching the
  // connection lazily; the connection handing joins and deltas to the sync.
  let connection: ReturnType<typeof createConnection>;
  const sync = createInitiativeSync({
    api: fake.api,
    domain,
    ui: createUiStore(),
    onForbidden: () => {},
    timers: clock.timers,
    channel: {
      subscribe: (id) => connection.subscribeInitiative(id),
      unsubscribe: (id) => connection.unsubscribeInitiative(id),
    },
  });
  connection = createConnection({
    transport: socket.factory,
    onStatus: () => {},
    onDelta: sync.onDelta,
    onJoined: sync.onJoined,
    onAccessRevoked: sync.onAccessRevoked,
    timers: clock.timers,
    leaveGraceMs: 5_000,
  });
  connection.connect();
  socket.get().open();

  const channel = (id: number) => {
    const found = socket.get().channels.find((c) => c.topic === `initiative:${id}`);
    if (found === undefined) throw new Error(`no channel for ${id}`);
    return found;
  };
  const seqOf = (id: number) => domain.get().trees[id]?.seq;
  const title = (id: number) => domain.get().trees[id]?.tasks[id * 10 + 1]?.title;

  return { socket, clock, fake, domain, sync, connection, channel, seqOf, title, synced };
}

/** The server's join reply for a topic at `seq`. */
const joinAt = (seqs: Record<number, number>) => (topic: string) => {
  const id = Number(topic.split(":")[1]);
  return { initiative_id: id, seq: seqs[id] };
};

describe("resync on rejoin (m04.03 3.3)", () => {
  it("behind: one re-read at once, no hold; then the screen is told it is level", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 1 });
    h.sync.onSynced(12, () => h.synced.push(12));
    h.sync.install(treeWith(12, 1));
    assert.deepEqual(h.synced, [12], "a server snapshot is level");
    h.sync.watch(12);
    assert.deepEqual(h.fake.calls, [], "the first join is level: nothing to read");
    assert.deepEqual(h.synced, [12, 12], "level is said, so pending work can go");

    h.fake.answer(12, treeWith(12, 3, "Three"));
    h.channel(12).rejoin({ initiative_id: 12, seq: 3 });
    await settle();
    assert.deepEqual(h.fake.calls, ["/initiatives/12"], "read now, not after the gap hold");
    assert.equal(h.seqOf(12), 3);
    assert.equal(h.title(12), "Three");
    assert.deepEqual(h.synced, [12, 12, 12], "and told again once the resync installed");
    assert.equal(h.clock.pendingCount(), 1, "only the snapshot-cache write is pending; no gap hold left");
  });

  it("level: no read", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 4 });
    h.sync.install(treeWith(12, 4));
    h.sync.watch(12);
    h.channel(12).rejoin();
    h.channel(12).rejoin({ initiative_id: 12, seq: 2 });
    await settle();
    assert.deepEqual(h.fake.calls, []);
    assert.equal(h.seqOf(12), 4);
  });

  it("no server snapshot yet: nothing — the mount read is on its way", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 9 });
    h.sync.onSynced(12, () => h.synced.push(12));
    h.sync.watch(12);
    h.channel(12).rejoin();
    await settle();
    assert.deepEqual(h.fake.calls, []);
    assert.deepEqual(h.synced, [], "the device's copy is not level with anything");
  });

  it("two joined Initiatives resync independently — a channel in its leave grace included", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 1, 13: 1 });
    h.sync.install(treeWith(12, 1));
    h.sync.install(treeWith(13, 1));
    const release = h.sync.watch(12);
    h.sync.watch(13);
    // The user walked from 12 to 13: 12's channel is still joined, in grace.
    release();
    assert.deepEqual(h.connection.joined(), [12, 13]);

    h.fake.answer(12, treeWith(12, 2, "Two"));
    h.fake.answer(13, treeWith(13, 7, "Seven"));
    h.channel(12).rejoin({ initiative_id: 12, seq: 2 });
    h.channel(13).rejoin({ initiative_id: 13, seq: 1 });
    await settle();
    assert.deepEqual(h.fake.calls, ["/initiatives/12"], "only the one behind reads");
    assert.equal(h.title(12), "Two");
    assert.equal(h.seqOf(13), 1);

    h.channel(13).rejoin({ initiative_id: 13, seq: 7 });
    await settle();
    assert.deepEqual(h.fake.calls, ["/initiatives/12", "/initiatives/13"]);
    assert.equal(h.title(13), "Seven");
  });

  it("a rejoin during an in-flight re-read is one read; the newest truth wins", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 1 });
    h.sync.install(treeWith(12, 1));
    h.sync.watch(12);

    h.fake.hold();
    h.fake.answer(12, treeWith(12, 5, "Five"));
    h.sync.onDelta(retitle(12, 3, "Three"));
    h.clock.flush();
    await settle();
    assert.equal(h.fake.parked(), 1, "the gap's re-read is out");

    h.channel(12).rejoin({ initiative_id: 12, seq: 5 });
    await settle();
    assert.equal(h.fake.parked(), 1, "no second read under the first");

    h.fake.release(0);
    await settle();
    assert.equal(h.seqOf(12), 5);
    assert.equal(h.title(12), "Five");
    assert.equal(h.fake.calls.length, 1);
  });

  it("a rejoin past a read still out is caught by the hold if that read lands short", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 1 });
    h.sync.install(treeWith(12, 1));
    h.sync.watch(12);

    h.fake.hold();
    h.fake.answer(12, treeWith(12, 3, "Three"));
    h.sync.onDelta(retitle(12, 3, "Three"));
    h.clock.flush();
    await settle();
    h.channel(12).rejoin({ initiative_id: 12, seq: 6 });
    h.fake.release(0);
    await settle();
    assert.equal(h.seqOf(12), 3, "the read that was out landed");

    h.fake.answer(12, treeWith(12, 6, "Six"));
    h.clock.flush();
    await settle();
    h.fake.release(1);
    await settle();
    assert.equal(h.seqOf(12), 6, "the hold's re-read caught up");
  });

  it("the first join's reply counts too: a device copy behind the server, with no read out, reads now", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 4 });
    h.fake.answer(12, treeWith(12, 4, "Four"));
    h.sync.onSynced(12, () => h.synced.push(12));
    h.sync.installCached(fromSnapshot(treeWith(12, 2)));
    h.sync.watch(12);
    await settle();
    assert.deepEqual(h.fake.calls, ["/initiatives/12"], "behind: read now");
    assert.equal(h.seqOf(12), 4);
    assert.deepEqual(h.synced, [12], "a server snapshot is in; now it is level");
  });

  it("a join that finds the device's copy level says nothing: only a server snapshot is level", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 2 });
    h.sync.onSynced(12, () => h.synced.push(12));
    h.sync.installCached(fromSnapshot(treeWith(12, 2)));
    h.sync.watch(12);
    await settle();
    assert.deepEqual(h.fake.calls, []);
    assert.deepEqual(h.synced, []);
  });
});

describe("repeated resync (m04.03 6.4)", () => {
  // Initiative `id` at `seq`, with two top-level tasks; only the first one's title varies.
  const twoTasks = (id: number, seq: number, title = "Original") =>
    buildTree([{ id: id * 10 + 1, title }, { id: id * 10 + 2, title: "Untouched" }], {
      id,
      name: "Kitchen",
      rootTaskId: id * 10,
      seq,
    });

  it("installs through the delta path: an unchanged row keeps its identity, and the same read again changes nothing", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 1 });
    h.sync.install(twoTasks(12, 1));
    h.sync.watch(12);
    const before = h.domain.get().trees[12]!;

    h.fake.answer(12, twoTasks(12, 3, "Three"));
    h.channel(12).rejoin({ initiative_id: 12, seq: 3 });
    await settle();
    const after = h.domain.get().trees[12]!;
    assert.equal(after.seq, 3);
    assert.equal(after.tasks[121]?.title, "Three");
    assert.equal(after.tasks[122], before.tasks[122], "the row the read left alone is the same object");
    assert.equal(after.childIds[120], before.childIds[120], "and so is the order");

    // The same resync again — a second rejoin at the same sequence, and the
    // same read once more — moves nothing, not even identity.
    h.channel(12).rejoin({ initiative_id: 12, seq: 3 });
    await settle();
    assert.equal(h.domain.get().trees[12], after, "level: no read, no new tree");
    assert.equal(h.fake.calls.length, 1);

    h.sync.install(twoTasks(12, 3, "Three"));
    const again = h.domain.get().trees[12]!;
    assert.equal(again.tasks, after.tasks, "an equal read keeps every record");
    assert.equal(again.seq, 3);
  });

  it("is Initiative-isolated: one Initiative's resync leaves the other's tree exactly as it was", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 1, 13: 1 });
    h.sync.install(twoTasks(12, 1));
    h.sync.install(twoTasks(13, 1));
    h.sync.watch(12);
    h.sync.watch(13);
    const other = h.domain.get().trees[13];

    h.fake.answer(12, twoTasks(12, 4, "Four"));
    h.channel(12).rejoin({ initiative_id: 12, seq: 4 });
    await settle();
    assert.equal(h.seqOf(12), 4);
    assert.equal(h.domain.get().trees[13], other, "not re-read, not rebuilt");
    assert.deepEqual(h.fake.calls, ["/initiatives/12"]);
  });

  it("stays gap-free under a burst of rejoins: one read at a time, and the last truth wins", async () => {
    const h = harness();
    h.socket.get().joinReply = joinAt({ 12: 1 });
    h.sync.install(twoTasks(12, 1));
    h.sync.watch(12);

    h.fake.hold();
    h.fake.answer(12, twoTasks(12, 2, "Two"));
    h.channel(12).rejoin({ initiative_id: 12, seq: 2 });
    h.channel(12).rejoin({ initiative_id: 12, seq: 3 });
    h.channel(12).rejoin({ initiative_id: 12, seq: 4 });
    await settle();
    assert.equal(h.fake.parked(), 1, "three rejoins, one read");

    h.fake.release(0);
    await settle();
    assert.equal(h.seqOf(12), 2, "the read that was out landed");
    // The read fell short of what the last join said: the hold re-reads, once.
    h.fake.answer(12, twoTasks(12, 4, "Four"));
    h.clock.flush();
    await settle();
    assert.equal(h.fake.parked(), 2);
    h.fake.release(1);
    await settle();
    assert.equal(h.seqOf(12), 4);
    assert.equal(h.title(12), "Four");
    assert.equal(h.fake.calls.length, 2, "bounded: no read per rejoin");
  });
});
