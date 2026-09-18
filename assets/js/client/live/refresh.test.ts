import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore } from "../state/ui.ts";
import { buildTree } from "../tree/gen.ts";
import type { TreeModel } from "../tree/model.ts";
import { fromSnapshot } from "../tree/model.ts";
import { fakeTimers } from "./fake_transport.ts";
import { SUMMARY_DEBOUNCE_MS, coalesce, createInitiativeSync } from "./refresh.ts";

const tree = (id: number, name: string): InitiativeTree => ({
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
  tasks: [],
});

/** The same read, as the model the store now holds. */
const model = (id: number, name: string) => fromSnapshot(tree(id, name));

/** A read that cannot be a tree: the one task claims a parent nobody holds. */
const badTree = (id: number): InitiativeTree => {
  const read = buildTree([{ id: id * 10 + 1 }], { id, name: "Broken", rootTaskId: id * 10 });
  (read.tasks[0] as { parent_id: number }).parent_id = 7777;
  return read;
};

const summary = (id: number, name: string, progress = 50): InitiativeSummary =>
  ({ id, name, progress }) as unknown as InitiativeSummary;

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

describe("what a `changed` event makes the client do (item 1.5)", () => {
  it("re-reads the Initiative it is holding", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const { api, calls } = fakeApi({ "/initiatives/12": tree(12, "New") });

    sync({ api, domain }).onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.deepEqual(calls, ["/initiatives/12"]);
    assert.equal(domain.get().trees[12]?.header.name, "New");
  });

  it("does not fetch a tree the tab is not holding", async () => {
    const domain = createDomainStore();
    const { api, calls } = fakeApi({ "/initiatives/12": tree(12, "New") });

    sync({ api, domain }).onChanged({ initiativeId: 12, kind: "task_moved", id: 5 });
    await settle();

    assert.deepEqual(calls, []);
  });

  it("patches that Initiative's row in the list once it has been read (item 4.6)", async () => {
    const domain = createDomainStore({
      trees: { 12: model(12, "Old") },
      initiativeSummaries: [summary(12, "Old"), summary(13, "Other")],
    });
    const other = domain.get().initiativeSummaries?.[1];
    const { api, calls } = fakeApi({
      "/initiatives/12": tree(12, "New"),
      "/initiatives/12/summary": summary(12, "New", 75),
    });
    const clock = fakeTimers();

    sync({ api, domain, timers: clock.timers }).onChanged({
      initiativeId: 12,
      kind: "task_updated",
      id: 5,
    });
    await settle();
    assert.deepEqual(calls, ["/initiatives/12"], "the row read waits out the debounce");

    clock.flush();
    await settle();

    assert.deepEqual(calls, ["/initiatives/12", "/initiatives/12/summary"]);
    assert.equal(domain.get().initiativeSummaries?.[0]?.name, "New");
    assert.equal(domain.get().initiativeSummaries?.[0]?.progress, 75);
    assert.equal(domain.get().initiativeSummaries?.[1], other, "the other row is untouched");
  });

  it("reads one row for a burst of changes, and none before the list is read", async () => {
    const domain = createDomainStore({ initiativeSummaries: [summary(12, "Old")] });
    const { api, calls } = fakeApi({ "/initiatives/12/summary": summary(12, "New") });
    const clock = fakeTimers();
    const unit = sync({ api, domain, timers: clock.timers });

    unit.onChanged({ initiativeId: 12, kind: "task_created", id: 1 });
    unit.onChanged({ initiativeId: 12, kind: "task_updated", id: 2 });
    unit.onChanged({ initiativeId: 12, kind: "task_moved", id: 3 });
    clock.flush();
    await settle();
    assert.deepEqual(calls, ["/initiatives/12/summary"]);

    const unread = createDomainStore();
    const idle = fakeApi({ "/initiatives/12/summary": summary(12, "New") });
    sync({ api: idle.api, domain: unread, timers: clock.timers }).onChanged({
      initiativeId: 12,
      kind: "task_updated",
      id: 1,
    });
    clock.flush();
    await settle();
    assert.deepEqual(idle.calls, [], "no list on the glass, nothing to patch");
  });

  it("a row read the list no longer holds adds nothing", async () => {
    const domain = createDomainStore({ initiativeSummaries: [summary(13, "Other")] });
    const { api } = fakeApi({ "/initiatives/12/summary": summary(12, "Stray") });
    const clock = fakeTimers();

    sync({ api, domain, timers: clock.timers }).onChanged({
      initiativeId: 12,
      kind: "task_updated",
      id: 5,
    });
    clock.flush();
    await settle();

    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
    );
  });

  it("never lets an older read land on top of a newer one", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const fake = fakeApi({});
    fake.answers("/initiatives/12", [tree(12, "First"), tree(12, "Second")]);
    fake.hold();

    const { onChanged } = sync({ api: fake.api, domain });
    onChanged({ initiativeId: 12, kind: "task_updated", id: 1 });
    onChanged({ initiativeId: 12, kind: "task_updated", id: 2 });
    await settle();
    assert.equal(fake.parked(), 2, "both reads are in flight");

    // The newer read answers first; the older one answers second and must be
    // dropped rather than written over it.
    fake.release(1);
    await settle();
    fake.release(0);
    await settle();

    assert.equal(domain.get().trees[12]?.header.name, "Second");
  });

  it("leaves what it has alone when the re-read fails", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const { api } = fakeApi({});

    sync({ api, domain }).onChanged({ initiativeId: 12, kind: "task_deleted", id: 5 });
    await settle();

    assert.equal(domain.get().trees[12]?.header.name, "Old");
  });
});

describe("a refresh that cannot be a tree (item 1.6.2)", () => {
  it("reads once more, and takes the second answer", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const ui = createUiStore();
    const fake = fakeApi({});
    fake.answers("/initiatives/12", [badTree(12), tree(12, "New")]);

    sync({ api: fake.api, domain, ui }).onChanged({
      initiativeId: 12,
      kind: "task_updated",
      id: 5,
    });
    await settle();

    assert.deepEqual(fake.calls, ["/initiatives/12", "/initiatives/12"]);
    assert.equal(domain.get().trees[12]?.header.name, "New");
    assert.deepEqual(ui.get().notices, [], "a recovered refresh said nothing");
  });

  it("says so once the second answer is bad too, and keeps the copy it has", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const ui = createUiStore();
    const fake = fakeApi({});
    fake.answers("/initiatives/12", [badTree(12), badTree(12)]);

    sync({ api: fake.api, domain, ui }).onChanged({
      initiativeId: 12,
      kind: "task_updated",
      id: 5,
    });
    await settle();

    assert.deepEqual(fake.calls, ["/initiatives/12", "/initiatives/12"]);
    assert.equal(domain.get().trees[12]?.header.name, "Old", "a bad read was drawn");
    assert.equal(ui.get().notices.length, 1);
    assert.equal(ui.get().notices[0]?.kind, "error");
  });
});

describe("what losing access makes the client do (item 1.5)", () => {
  it("a refetch still in flight cannot put back what a revocation removed", async () => {
    // The race: `changed` starts a read, access is taken away while it is out,
    // and the answer arrives last. It must be dropped, not written.
    const domain = createDomainStore({
      trees: { 12: model(12, "Old") },
      initiativeSummaries: [summary(12, "Old"), summary(13, "Other")],
    });
    const ui = createUiStore({ route: { kind: "initiative", id: 12 } });
    const fake = fakeApi({
      "/initiatives/12": tree(12, "Back from the dead"),
      // What the server really says once the user is out: no row for 12.
      "/initiatives": [summary(13, "Other")],
    });
    fake.hold();
    let forbidden = 0;

    const unit = sync({ api: fake.api, domain, ui, onForbidden: () => (forbidden += 1) });
    unit.onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();
    assert.equal(fake.parked(), 1, "the tree read is in flight");

    unit.onAccessRevoked(12);
    assert.equal(domain.get().trees[12], undefined);
    assert.equal(forbidden, 1);

    fake.release(0);
    await settle();
    await settle();

    assert.equal(domain.get().trees[12], undefined, "the stale read wrote it back");

    if (fake.parked() > 1) fake.release(1);
    await settle();
    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
    );
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
    unit.onChanged({ initiativeId: 12, kind: "members_changed", id: 12 });
    unit.onAccessRevoked(12);
    clock.flush();
    await settle();
    assert.deepEqual(fake.calls, []);

    // In flight: the read is out when access goes; its answer must be dropped.
    domain.set((state) => ({ ...state, initiativeSummaries: [summary(12, "Old"), summary(13, "Other")] }));
    fake.hold();
    unit.onChanged({ initiativeId: 12, kind: "members_changed", id: 12 });
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

  it("lets a read begun after the revocation land (access given back)", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const ui = createUiStore({ route: { kind: "initiatives" } });
    const fake = fakeApi({ "/initiatives/12": tree(12, "Fresh") });

    const unit = sync({ api: fake.api, domain, ui });
    unit.onAccessRevoked(12);

    // The user is let back in, the screen reloads the tree, and a change lands.
    domain.set((state) => ({
      ...state,
      trees: { ...state.trees, 12: model(12, "Old") },
    }));
    unit.onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.equal(domain.get().trees[12]?.header.name, "Fresh");
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
  it("caches a tree the guard let through", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const snapshots = fakeSnapshots();
    const backend = fakeApi({ "/initiatives/12": tree(12, "New") });

    sync({ api: backend.api, domain, snapshots }).onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.deepEqual(snapshots.cached, [12]);
  });

  it("deletes the snapshot when access is taken away", () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const snapshots = fakeSnapshots();

    sync({ domain, snapshots }).onAccessRevoked(12);

    assert.deepEqual(snapshots.forgotten, [12], "the copy on disk goes too (spec §12)");
  });

  it("does not cache a tree that arrived after access was taken away", async () => {
    const domain = createDomainStore({ trees: { 12: model(12, "Old") } });
    const snapshots = fakeSnapshots();
    const backend = fakeApi({ "/initiatives/12": tree(12, "New") });
    backend.hold();

    const unit = sync({ api: backend.api, domain, snapshots });
    unit.onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();
    unit.onAccessRevoked(12);
    backend.release(0);
    await settle();

    assert.deepEqual(snapshots.cached, [], "the guard rejected it, so it was never cached");
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

    fake.hold();
    unit.onChanged({ initiativeId: 12, kind: "task_updated", id: 1 });
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
