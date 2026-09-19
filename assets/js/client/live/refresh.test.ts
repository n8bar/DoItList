import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree, Member } from "../api/types.ts";
import type { DomainState } from "../state/domain.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore } from "../state/ui.ts";
import { buildTree } from "../tree/gen.ts";
import type { TreeModel } from "../tree/model.ts";
import { fromSnapshot } from "../tree/model.ts";
import { addTask, updateFields } from "../tree/ops.ts";
import type { Flight } from "../tree/optimistic.ts";
import type { DeltaEnvelope } from "./envelope.ts";
import { envelope, record } from "./fake_envelope.ts";
import { fakeTimers } from "./fake_transport.ts";
import type { Settled } from "./session.ts";
import { BUFFER_LIMIT } from "./session.ts";
import { SUMMARY_DEBOUNCE_MS, coalesce, createInitiativeSync } from "./refresh.ts";

const tree = (id: number, name: string, seq = 1): InitiativeTree => ({
  id,
  name,
  subtitle: null,
  role: "owner",
  progress: 50,
  progress_calc: "leaf_average",
  unit_count: 2,
  index_style: "numerical",
  root_task_id: id * 10,
  version: 1,
  seq,
  tasks: [],
});

/** The same read, as the model the store now holds. */
const model = (id: number, name: string) => fromSnapshot(tree(id, name));

/** Initiative `id` at `seq`, with one top-level task `id*10+1`. */
const treeWith = (id: number, seq: number, title = "Original", indexStyle = "numerical") =>
  buildTree([{ id: id * 10 + 1, title }], { id, name: "Kitchen", rootTaskId: id * 10, seq, indexStyle });

/** A read that cannot be a tree: the one task claims a parent nobody holds. */
const badTree = (id: number, seq = 9): InitiativeTree => {
  const read = buildTree([{ id: id * 10 + 1 }], { id, name: "Broken", rootTaskId: id * 10, seq });
  (read.tasks[0] as { parent_id: number }).parent_id = 7777;
  return read;
};

/** An envelope on Initiative `id` at `seq`. */
const delta = (id: number, seq: number, parts: Partial<DeltaEnvelope> = {}): DeltaEnvelope => ({
  ...envelope(seq, parts),
  initiativeId: id,
});

/** Retitles Initiative `id`'s one task. */
const retitle = (id: number, seq: number, title: string) =>
  delta(id, seq, { upserts: [record(id * 10 + 1, id * 10, 0, { title, version: 2 })] });

const summary = (id: number, name: string, progress = 50): InitiativeSummary =>
  ({ id, name, progress }) as unknown as InitiativeSummary;

const member = (userId: number, role: Member["role"]): Member => ({
  user_id: userId,
  role,
  name: `User ${userId}`,
  username: `user${userId}`,
});

function fakeApi(responses: Record<string, unknown>) {
  const calls: string[] = [];
  /** Reads parked until a test lets them answer, so ordering can be forced. */
  const gates: Array<(value: unknown) => void> = [];
  const api = {
    get: <T,>(path: string): Promise<Result<T>> => {
      calls.push(path);
      // Bound now, not at release: which answer a read gets is decided when
      // it is made, so a test can hand them back out of order.
      const queued = queue[path];
      const value = queued && queued.length > 0 ? queued.shift() : responses[path];
      const answer = (): Result<T> =>
        value === undefined
          ? { ok: false, error: { code: "not_found", status: 404, message: "gone" } }
          : { ok: true, data: value as T };
      if (!gated) return Promise.resolve(answer());
      return new Promise<Result<T>>((resolve) => {
        gates.push(() => resolve(answer()));
      });
    },
    post: () => Promise.reject(new Error("not used")),
    refreshSession: () => Promise.reject(new Error("not used")),
    csrfToken: () => "token",
  } as unknown as ApiClient;

  const queue: Record<string, unknown[]> = {};
  let gated = false;

  return {
    api,
    calls,
    /** Park every read from here on. */
    hold: () => {
      gated = true;
    },
    /** Queue the successive answers one path will give. */
    answers: (path: string, values: unknown[]) => {
      queue[path] = [...values];
    },
    /** Let parked read number `index` answer. */
    release: (index: number) => gates[index]?.(undefined),
    parked: () => gates.length,
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

/** The unit under test, with whatever the case doesn't care about filled in. */
function sync(parts: {
  api?: ApiClient;
  domain?: ReturnType<typeof createDomainStore>;
  ui?: ReturnType<typeof createUiStore>;
  onForbidden?: () => void;
  snapshots?: { cacheTree(model: TreeModel): void; forgetTree(id: number): Promise<void> };
  timers?: ReturnType<typeof fakeTimers>["timers"];
}) {
  return createInitiativeSync({
    api: parts.api ?? fakeApi({}).api,
    domain: parts.domain ?? createDomainStore(),
    ui: parts.ui ?? createUiStore(),
    onForbidden: parts.onForbidden ?? (() => {}),
    ...(parts.snapshots === undefined ? {} : { snapshots: parts.snapshots }),
    ...(parts.timers === undefined ? {} : { timers: parts.timers }),
  });
}

/** Records what the local cache was asked to do. */
const fakeSnapshots = () => {
  const cached: number[] = [];
  const forgotten: number[] = [];
  return {
    cached,
    forgotten,
    cacheTree: (value: TreeModel) => void cached.push(value.initiativeId),
    forgetTree: (id: number) => {
      forgotten.push(id);
      return Promise.resolve();
    },
  };
};

const title = (domain: ReturnType<typeof createDomainStore>, id: number) =>
  domain.get().trees[id]?.tasks[id * 10 + 1]?.title;

describe("what a delta makes the client do (item 1.4)", () => {
  it("applies the next delta to the tree it holds, without a read", async () => {
    const domain = createDomainStore();
    const { api, calls } = fakeApi({});
    const unit = sync({ api, domain });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 2, "Doors"));
    await settle();

    assert.equal(title(domain, 12), "Doors");
    assert.equal(domain.get().trees[12]?.seq, 2);
    assert.deepEqual(calls, []);
  });

  it("holds a delta that arrives before the snapshot, and applies it after (spec §4)", () => {
    const domain = createDomainStore();
    const unit = sync({ domain });

    unit.onDelta(retitle(12, 2, "Doors"));
    assert.equal(domain.get().trees[12], undefined, "nothing to show yet");

    unit.install(treeWith(12, 1));
    assert.equal(title(domain, 12), "Doors");
    assert.equal(domain.get().trees[12]?.seq, 2);
  });

  it("a delta the snapshot already covers is dropped", () => {
    const domain = createDomainStore();
    const unit = sync({ domain });
    unit.onDelta(retitle(12, 2, "Stale"));
    unit.install(treeWith(12, 2, "Read"));
    assert.equal(title(domain, 12), "Read");
  });

  it("patches that Initiative's row in the list once it has been read (item 4.6)", async () => {
    const domain = createDomainStore({
      initiativeSummaries: [summary(12, "Old"), summary(13, "Other")],
    });
    const other = domain.get().initiativeSummaries?.[1];
    const { api, calls } = fakeApi({ "/initiatives/12/summary": summary(12, "New", 75) });
    const clock = fakeTimers();
    const unit = sync({ api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 2, "Doors"));
    await settle();
    assert.deepEqual(calls, [], "the row read waits out the debounce");

    clock.flush();
    await settle();

    assert.deepEqual(calls, ["/initiatives/12/summary"]);
    assert.equal(domain.get().initiativeSummaries?.[0]?.name, "New");
    assert.equal(domain.get().initiativeSummaries?.[0]?.progress, 75);
    assert.equal(domain.get().initiativeSummaries?.[1], other, "the other row is untouched");
  });

  it("reads one row for a burst of deltas, and none before the list is read", async () => {
    const domain = createDomainStore({ initiativeSummaries: [summary(12, "Old")] });
    const { api, calls } = fakeApi({ "/initiatives/12/summary": summary(12, "New") });
    const clock = fakeTimers();
    const unit = sync({ api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 2, "a"));
    unit.onDelta(retitle(12, 3, "b"));
    unit.onDelta(retitle(12, 4, "c"));
    clock.flush();
    await settle();
    assert.deepEqual(calls, ["/initiatives/12/summary"]);

    const unread = createDomainStore();
    const idle = fakeApi({ "/initiatives/12/summary": summary(12, "New") });
    const quiet = sync({ api: idle.api, domain: unread, timers: clock.timers });
    quiet.install(treeWith(12, 1));
    quiet.onDelta(retitle(12, 2, "a"));
    clock.flush();
    await settle();
    assert.deepEqual(idle.calls, [], "no list on the glass, nothing to patch");
  });

  it("a row read the list no longer holds adds nothing", async () => {
    const domain = createDomainStore({ initiativeSummaries: [summary(13, "Other")] });
    const { api } = fakeApi({ "/initiatives/12/summary": summary(12, "Stray") });
    const clock = fakeTimers();
    const unit = sync({ api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 2, "a"));
    clock.flush();
    await settle();

    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
    );
  });

  it("a header patch with a new index style relabels the tree (item 7.7)", () => {
    const domain = createDomainStore();
    const unit = sync({ domain });
    unit.install(treeWith(12, 1));
    assert.equal(domain.get().trees[12]?.tasks[121]?.index, "1");

    unit.onDelta(
      delta(12, 2, {
        initiative: {
          version: 2,
          name: "Kitchen",
          subtitle: "",
          progress: 0,
          unit_count: 1,
          progress_calc: "leaf_average",
          index_style: "roman",
        },
      }),
    );

    assert.equal(domain.get().trees[12]?.indexStyle, "roman");
    assert.equal(domain.get().trees[12]?.tasks[121]?.index, "I");
  });

  it("a members change re-reads the members and adopts this user's own role", async () => {
    const domain = createDomainStore({ user: { id: 5 } as unknown as DomainState["user"] });
    const { api, calls } = fakeApi({ "/initiatives/12/members": [member(5, "viewer"), member(6, "owner")] });
    const unit = sync({ api, domain });

    unit.install(treeWith(12, 1));
    assert.equal(domain.get().trees[12]?.header.role, "owner");
    unit.onDelta(delta(12, 2, { membersChanged: true }));
    await settle();

    assert.deepEqual(calls, ["/initiatives/12/members"]);
    assert.equal(domain.get().members[12]?.length, 2);
    assert.equal(domain.get().trees[12]?.header.role, "viewer");
  });
});

describe("a gap re-reads the tree (1.4.4)", () => {
  it("after the hold; held deltas newer than the read follow it", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12": treeWith(12, 2, "Two") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 3, "Three"));
    await settle();
    assert.deepEqual(fake.calls, [], "the gap is given a moment to fill");
    assert.equal(title(domain, 12), "Original", "nothing skipped ahead");

    clock.flush();
    await settle();

    assert.deepEqual(fake.calls, ["/initiatives/12"]);
    assert.equal(title(domain, 12), "Three");
    assert.equal(domain.get().trees[12]?.seq, 3);
  });

  it("a read newer than what was held is truth; the held deltas are moot", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12": treeWith(12, 4, "Four") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 3, "Three"));
    clock.flush();
    await settle();

    assert.equal(title(domain, 12), "Four");
    assert.equal(domain.get().trees[12]?.seq, 4);
  });

  it("a gap that fills before the hold expires never reads", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12": treeWith(12, 9, "Never") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 3, "Three"));
    unit.onDelta(retitle(12, 2, "Two"));
    clock.flush();
    await settle();

    assert.deepEqual(fake.calls, []);
    assert.equal(title(domain, 12), "Three");
    assert.equal(domain.get().trees[12]?.seq, 3);
  });

  it("the buffer overflowing reads at once", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12": treeWith(12, 100, "Caught up") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    for (let seq = 3; seq <= 3 + BUFFER_LIMIT; seq += 1) unit.onDelta(retitle(12, seq, "x"));
    await settle();

    assert.deepEqual(fake.calls, ["/initiatives/12"], "no waiting on the hold");
    assert.equal(title(domain, 12), "Caught up");
  });

  it("leaves what it has alone when the re-read fails", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({});
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 3, "Three"));
    clock.flush();
    await settle();

    assert.deepEqual(fake.calls, ["/initiatives/12"]);
    assert.equal(title(domain, 12), "Original");
    assert.equal(domain.get().trees[12]?.seq, 1);
  });

  it("never lets an older read land on top of a newer one", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12": treeWith(12, 2, "First") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    fake.hold();
    unit.onDelta(retitle(12, 3, "Three"));
    clock.flush();
    await settle();
    assert.equal(fake.parked(), 1, "the re-read is in flight");

    // The screen reads again itself (a reload) and lands something newer
    // before the slow re-read answers; the answer must be dropped.
    unit.install(treeWith(12, 70, "Second"));
    fake.release(0);
    await settle();

    assert.equal(title(domain, 12), "Second");
    assert.equal(domain.get().trees[12]?.seq, 70);
  });

  it("a burst past the buffer asks for one re-read, not one per delta", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12": treeWith(12, 200, "Caught up") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    fake.hold();
    for (let seq = 3; seq <= 3 + BUFFER_LIMIT * 2; seq += 1) unit.onDelta(retitle(12, seq, "x"));
    await settle();
    assert.equal(fake.parked(), 1);

    fake.release(0);
    await settle();
    assert.equal(title(domain, 12), "Caught up");
  });
});

describe("a re-read that cannot be a tree (item 1.6.2)", () => {
  it("reads once more, and takes the second answer", async () => {
    const domain = createDomainStore();
    const ui = createUiStore();
    const fake = fakeApi({});
    fake.answers("/initiatives/12", [badTree(12), treeWith(12, 3, "New")]);
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, ui, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 3, "Three"));
    clock.flush();
    await settle();

    assert.deepEqual(fake.calls, ["/initiatives/12", "/initiatives/12"]);
    assert.equal(title(domain, 12), "New");
    assert.deepEqual(ui.get().notices, [], "a recovered refresh said nothing");
  });

  it("says so once the second answer is bad too, and keeps the copy it has", async () => {
    const domain = createDomainStore();
    const ui = createUiStore();
    const fake = fakeApi({});
    fake.answers("/initiatives/12", [badTree(12), badTree(12)]);
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, ui, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 3, "Three"));
    clock.flush();
    await settle();

    assert.deepEqual(fake.calls, ["/initiatives/12", "/initiatives/12"]);
    assert.equal(title(domain, 12), "Original", "a bad read was drawn");
    assert.equal(ui.get().notices.length, 1);
    assert.equal(ui.get().notices[0]?.kind, "error");
  });

  it("the screen's own snapshot throws the same way, so it re-reads", () => {
    const unit = sync({});
    assert.throws(() => unit.install(badTree(12)));
    assert.equal(unit.canonical(12), undefined);
  });
});

describe("the screen's own writes go through the session (1.4.1)", () => {
  const addFlight = (key: string, tempId = -1): Flight => ({
    key,
    predict: (base) => {
      const result = addTask(base, { tempId, parentId: 120, position: 1, title: "New" });
      return "model" in result ? result.model : base;
    },
    tempId,
  });
  const editFlight = (key: string): Flight => ({
    key,
    predict: (base) => updateFields(base, 121, { title: "Mine" }).model,
    tempId: null,
  });
  const addReply = {
    upserts: [{ id: 122, parent_id: 120, position: 1, title: "New", version: 1 }],
    removed: [],
  };
  const broadcast = (key: string) =>
    delta(12, 2, { originKey: key, upserts: [record(122, 120, 1, { title: "New" })] });
  const rootIds = (domain: ReturnType<typeof createDomainStore>) => domain.get().trees[12]?.childIds[120];

  it("the prediction shows at once, and someone else's delta lands under it", () => {
    const domain = createDomainStore();
    const unit = sync({ domain });
    unit.install(treeWith(12, 1));

    const shown = unit.begin(12, editFlight("k"));
    assert.equal(shown?.tasks[121]?.title, "Mine");
    assert.equal(title(domain, 12), "Mine");
    assert.equal(unit.canonical(12)?.tasks[121]?.title, "Original", "truth is not the guess");

    unit.onDelta(delta(12, 2, { upserts: [record(121, 120, 0, { title: "Theirs", priority: "high" })] }));
    assert.equal(title(domain, 12), "Mine", "the guess is re-run over their change");
    assert.equal(domain.get().trees[12]?.tasks[121]?.priority, "high");
    assert.equal(unit.canonical(12)?.tasks[121]?.title, "Theirs");
  });

  it("broadcast first: the session settles the write and tells the screen; the reply then does nothing", () => {
    const domain = createDomainStore();
    const unit = sync({ domain });
    unit.install(treeWith(12, 1));
    const settled: Settled[] = [];
    const stop = unit.onSettled(12, (s) => settled.push(s));

    unit.begin(12, addFlight("k"));
    assert.deepEqual(rootIds(domain), [121, -1]);

    unit.onDelta(broadcast("k"));
    assert.deepEqual(rootIds(domain), [121, 122], "exactly one row, the server's");
    assert.deepEqual(settled.map((s) => [s.flight.key, s.flight.tempId, s.createdId]), [["k", -1, 122]]);

    const before = domain.get().trees[12];
    assert.deepEqual(unit.succeed(12, "k", addReply, 2), { createdId: null, tempId: null });
    assert.equal(domain.get().trees[12], before, "nothing left to do");

    stop();
    unit.begin(12, addFlight("k2", -2));
    unit.onDelta(delta(12, 3, { originKey: "k2", upserts: [record(123, 120, 2)] }));
    assert.equal(settled.length, 1, "unsubscribed");
  });

  it("reply first: the reply settles the write; its broadcast then lands the full record", () => {
    const domain = createDomainStore();
    const unit = sync({ domain });
    unit.install(treeWith(12, 1));
    const settled: Settled[] = [];
    unit.onSettled(12, (s) => settled.push(s));

    unit.begin(12, addFlight("k"));
    assert.deepEqual(unit.succeed(12, "k", addReply, 2), { createdId: 122, tempId: -1 });
    assert.deepEqual(rootIds(domain), [121, 122]);

    unit.onDelta(broadcast("k"));
    assert.deepEqual(rootIds(domain), [121, 122], "still one row");
    assert.equal(domain.get().trees[12]?.seq, 2);
    assert.equal(settled.length, 0, "the reply settled it, not the broadcast");
  });

  it("a rejection reverts to truth plus what is still pending; a header patch lands under it", () => {
    const domain = createDomainStore();
    const unit = sync({ domain });
    unit.install(treeWith(12, 1));

    unit.begin(12, editFlight("k"));
    unit.patchHeader(12, (header) => ({ ...header, name: "Renamed" }));
    assert.equal(domain.get().trees[12]?.header.name, "Renamed");
    assert.equal(title(domain, 12), "Mine");

    unit.reject(12, "k");
    assert.equal(title(domain, 12), "Original");
    assert.equal(domain.get().trees[12]?.header.name, "Renamed");
  });

  it("a write on an Initiative with no snapshot shows nothing", () => {
    const unit = sync({});
    assert.equal(unit.begin(12, editFlight("k")), undefined);
  });
});

describe("what losing access makes the client do (item 1.5)", () => {
  it("a re-read still in flight cannot put back what a revocation removed", async () => {
    // The race: a gap starts a read, access is taken away while it is out,
    // and the answer arrives last. It must be dropped, not written.
    const domain = createDomainStore({
      initiativeSummaries: [summary(12, "Old"), summary(13, "Other")],
    });
    const ui = createUiStore({ route: { kind: "initiative", id: 12 } });
    const fake = fakeApi({
      "/initiatives/12": treeWith(12, 3, "Back from the dead"),
      // What the server really says once the user is out: no row for 12.
      "/initiatives": [summary(13, "Other")],
    });
    const clock = fakeTimers();
    let forbidden = 0;

    const unit = sync({ api: fake.api, domain, ui, timers: clock.timers, onForbidden: () => (forbidden += 1) });
    unit.install(treeWith(12, 1));
    fake.hold();
    unit.onDelta(retitle(12, 3, "Three"));
    clock.flush();
    await settle();
    assert.equal(fake.parked(), 1, "the tree read is in flight");

    unit.onAccessRevoked(12);
    assert.equal(domain.get().trees[12], undefined);
    assert.equal(unit.canonical(12), undefined);
    assert.equal(forbidden, 1);

    fake.release(0);
    await settle();
    await settle();

    assert.equal(domain.get().trees[12], undefined, "the stale read wrote it back");
    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
    );
  });

  it("held deltas and the hold go with the session", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12": treeWith(12, 3, "Never") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 3, "Three"));
    unit.onAccessRevoked(12);
    clock.flush();
    await settle();

    assert.deepEqual(fake.calls, [], "no read for a session that is gone");
    // Let back in: the screen reads again, and the old held delta is not waiting.
    unit.install(treeWith(12, 2, "Again"));
    assert.equal(title(domain, 12), "Again");
    assert.equal(domain.get().trees[12]?.seq, 2);
  });

  it("a list read in flight cannot put the row back either", async () => {
    // A revalidation of the index is out when access goes — and that read is
    // the one carrying a row the user may no longer have.
    const domain = createDomainStore({
      initiativeSummaries: [summary(12, "Old"), summary(13, "Other")],
    });
    const ui = createUiStore({ route: { kind: "initiatives" } });
    const fake = fakeApi({ "/initiatives": [summary(12, "Old"), summary(13, "Other")] });
    fake.hold();

    const unit = sync({ api: fake.api, domain, ui });
    unit.revalidateList();
    await settle();
    assert.equal(fake.parked(), 1, "the index read is in flight");

    unit.onAccessRevoked(12);
    fake.release(0);
    await settle();

    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
      "a stale index read put the revoked row back",
    );
  });

  it("a pending row read is dropped, and one in flight cannot land", async () => {
    const domain = createDomainStore({
      initiativeSummaries: [summary(12, "Old"), summary(13, "Other")],
    });
    const ui = createUiStore({ route: { kind: "initiatives" } });
    const fake = fakeApi({ "/initiatives/12/summary": summary(12, "Old") });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, ui, timers: clock.timers });

    // Pending: revoked before the debounce fires, so no read goes out at all.
    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 2, "a"));
    unit.onAccessRevoked(12);
    clock.flush();
    await settle();
    assert.deepEqual(fake.calls, []);

    // In flight: the read is out when access goes; its answer must be dropped.
    domain.set((state) => ({ ...state, initiativeSummaries: [summary(12, "Old"), summary(13, "Other")] }));
    fake.hold();
    unit.install(treeWith(12, 1));
    unit.onDelta(retitle(12, 2, "a"));
    clock.flush();
    await settle();
    assert.equal(fake.parked(), 1, "the row read is in flight");
    unit.onAccessRevoked(12);
    fake.release(0);
    await settle();

    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
      "a stale row read put the revoked row back",
    );
  });

  it("a members read in flight cannot land after the revocation", async () => {
    const domain = createDomainStore();
    const fake = fakeApi({ "/initiatives/12/members": [member(5, "viewer")] });
    fake.hold();
    const unit = sync({ api: fake.api, domain });

    unit.install(treeWith(12, 1));
    unit.onDelta(delta(12, 2, { membersChanged: true }));
    await settle();
    assert.equal(fake.parked(), 1);
    unit.onAccessRevoked(12);
    fake.release(0);
    await settle();

    assert.equal(domain.get().members[12], undefined);
  });

  it("lets a read begun after the revocation land (access given back)", () => {
    const domain = createDomainStore();
    const ui = createUiStore({ route: { kind: "initiatives" } });
    const unit = sync({ domain, ui });

    unit.install(treeWith(12, 1));
    unit.onAccessRevoked(12);

    // The user is let back in, the screen reloads the tree, and a delta lands.
    unit.install(treeWith(12, 5, "Fresh"));
    unit.onDelta(retitle(12, 6, "Fresher"));

    assert.equal(title(domain, 12), "Fresher");
  });

  it("forgets the Initiative, tree and index row alike", () => {
    const domain = createDomainStore({
      trees: { 12: model(12, "Gone"), 13: model(13, "Kept") },
      initiativeSummaries: [summary(12, "Gone"), summary(13, "Kept")],
    });
    const ui = createUiStore({ route: { kind: "initiatives" } });

    sync({ domain, ui }).onAccessRevoked(12);

    assert.equal(domain.get().trees[12], undefined);
    assert.equal(domain.get().trees[13]?.header.name, "Kept");
    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
    );
  });

  it("says so when the user is looking at it", () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Gone") } });
    const ui = createUiStore({ route: { kind: "initiative", id: 12 } });
    let forbidden = 0;

    sync({ domain, ui, onForbidden: () => (forbidden += 1) }).onAccessRevoked(12);

    assert.equal(forbidden, 1);
  });

  it("does not hijack the screen for an Initiative the user is not on", () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Gone") } });
    const ui = createUiStore({ route: { kind: "initiative", id: 13 } });
    let forbidden = 0;

    sync({ domain, ui, onForbidden: () => (forbidden += 1) }).onAccessRevoked(12);

    assert.equal(forbidden, 0);
    assert.equal(domain.get().trees[12], undefined, "the copy still goes");
  });
});

describe("the local cache follows the same rules (items 3.4–3.6)", () => {
  it("caches every snapshot it installs, and nothing a delta produced", async () => {
    const domain = createDomainStore();
    const snapshots = fakeSnapshots();
    const backend = fakeApi({ "/initiatives/12": treeWith(12, 3, "New") });
    const clock = fakeTimers();
    const unit = sync({ api: backend.api, domain, snapshots, timers: clock.timers });

    unit.install(treeWith(12, 1));
    assert.deepEqual(snapshots.cached, [12]);
    unit.onDelta(retitle(12, 2, "Two"));
    assert.deepEqual(snapshots.cached, [12], "a delta is not a snapshot");

    unit.onDelta(retitle(12, 4, "Four"));
    clock.flush();
    await settle();
    assert.deepEqual(snapshots.cached, [12, 12], "the re-read is");
  });

  it("deletes the snapshot when access is taken away", () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const snapshots = fakeSnapshots();

    sync({ domain, snapshots }).onAccessRevoked(12);

    assert.deepEqual(snapshots.forgotten, [12], "the copy on disk goes too (spec §12)");
  });

  it("does not cache a tree that arrived after access was taken away", async () => {
    const domain = createDomainStore();
    const snapshots = fakeSnapshots();
    const backend = fakeApi({ "/initiatives/12": treeWith(12, 3, "New") });
    const clock = fakeTimers();
    const unit = sync({ api: backend.api, domain, snapshots, timers: clock.timers });

    unit.install(treeWith(12, 1));
    backend.hold();
    unit.onDelta(retitle(12, 3, "Three"));
    clock.flush();
    await settle();
    unit.onAccessRevoked(12);
    backend.release(0);
    await settle();

    assert.deepEqual(snapshots.cached, [12], "the guard rejected the re-read, so it was never cached");
    assert.deepEqual(snapshots.forgotten, [12]);
  });
});

describe("coalescing a burst into one read (item 4.6)", () => {
  it("runs once per key, after the last request", () => {
    const clock = fakeTimers();
    const ran: number[] = [];
    const burst = coalesce<number>(clock.timers, 300, (key) => ran.push(key));

    burst.request(12);
    burst.request(12);
    burst.request(13);
    assert.deepEqual(burst.pending(), [12, 13]);
    assert.equal(clock.pendingCount(), 2, "a repeat restarts the wait, it does not add one");

    clock.flush();
    assert.deepEqual(ran, [12, 13]);
    assert.deepEqual(burst.pending(), []);
  });

  it("cancel drops a key's pending work and nothing else", () => {
    const clock = fakeTimers();
    const ran: number[] = [];
    const burst = coalesce<number>(clock.timers, 300, (key) => ran.push(key));

    burst.request(12);
    burst.request(13);
    burst.cancel(12);
    burst.cancel(99);
    clock.flush();

    assert.deepEqual(ran, [13]);
  });

  it("the sync's debounce is short", () => {
    assert.ok(SUMMARY_DEBOUNCE_MS > 0 && SUMMARY_DEBOUNCE_MS <= 500);
  });
});

describe("revalidating the index behind a list on the glass (item 4.6)", () => {
  it("patches changed rows, adds new ones, drops missing ones, keeps the rest", async () => {
    const domain = createDomainStore({
      initiativeSummaries: [summary(12, "Old"), summary(13, "Same"), summary(14, "Gone")],
    });
    const same = domain.get().initiativeSummaries?.[1];
    const { api, calls } = fakeApi({
      "/initiatives": [summary(15, "New"), summary(12, "Renamed"), summary(13, "Same")],
    });

    sync({ api, domain }).revalidateList();
    await settle();

    assert.deepEqual(calls, ["/initiatives"]);
    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => [s.id, s.name]),
      [
        [15, "New"],
        [12, "Renamed"],
        [13, "Same"],
      ],
    );
    assert.equal(domain.get().initiativeSummaries?.[2], same, "an unchanged row keeps its object");
  });

  it("does nothing before the list has been read, or when the read fails", async () => {
    const unread = createDomainStore();
    const idle = fakeApi({ "/initiatives": [summary(12, "New")] });
    sync({ api: idle.api, domain: unread }).revalidateList();
    await settle();
    assert.deepEqual(idle.calls, []);
    assert.equal(unread.get().initiativeSummaries, null);

    const domain = createDomainStore({ initiativeSummaries: [summary(12, "Old")] });
    const before = domain.get().initiativeSummaries;
    sync({ api: fakeApi({}).api, domain }).revalidateList();
    await settle();
    assert.equal(domain.get().initiativeSummaries, before, "a failed read changes nothing");
  });

  it("a list read outranks a row read still in flight", async () => {
    const domain = createDomainStore({ initiativeSummaries: [summary(12, "Old")] });
    const fake = fakeApi({
      "/initiatives/12/summary": summary(12, "Row"),
      "/initiatives": [summary(12, "List")],
    });
    const clock = fakeTimers();
    const unit = sync({ api: fake.api, domain, timers: clock.timers });

    unit.install(treeWith(12, 1));
    fake.hold();
    unit.onDelta(retitle(12, 2, "a"));
    clock.flush();
    await settle();
    unit.revalidateList();
    await settle();
    assert.equal(fake.parked(), 2);

    fake.release(1);
    await settle();
    fake.release(0);
    await settle();

    assert.equal(domain.get().initiativeSummaries?.[0]?.name, "List");
  });
});
