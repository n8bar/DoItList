import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore } from "../state/ui.ts";
import { createInitiativeSync } from "./refresh.ts";

const tree = (id: number, name: string): InitiativeTree =>
  ({ id, name, progress: 50, unit_count: 2, root: null }) as unknown as InitiativeTree;

const summary = (id: number, name: string): InitiativeSummary =>
  ({ id, name, progress: 50 }) as unknown as InitiativeSummary;

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
  snapshots?: { cacheTree(tree: InitiativeTree): void; forgetTree(id: number): Promise<void> };
}) {
  return createInitiativeSync({
    api: parts.api ?? fakeApi({}).api,
    domain: parts.domain ?? createDomainStore(),
    ui: parts.ui ?? createUiStore(),
    onForbidden: parts.onForbidden ?? (() => {}),
    ...(parts.snapshots === undefined ? {} : { snapshots: parts.snapshots }),
  });
}

/** Records what the local cache was asked to do. */
const fakeSnapshots = () => {
  const cached: number[] = [];
  const forgotten: number[] = [];
  return {
    cached,
    forgotten,
    cacheTree: (value: InitiativeTree) => void cached.push(value.id),
    forgetTree: (id: number) => {
      forgotten.push(id);
      return Promise.resolve();
    },
  };
};

describe("what a `changed` event makes the client do (item 1.5)", () => {
  it("re-reads the Initiative it is holding", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const { api, calls } = fakeApi({ "/initiatives/12": tree(12, "New") });

    sync({ api, domain }).onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.deepEqual(calls, ["/initiatives/12"]);
    assert.equal(domain.get().initiativeTrees[12]?.name, "New");
  });

  it("does not fetch a tree the tab is not holding", async () => {
    const domain = createDomainStore();
    const { api, calls } = fakeApi({ "/initiatives/12": tree(12, "New") });

    sync({ api, domain }).onChanged({ initiativeId: 12, kind: "task_moved", id: 5 });
    await settle();

    assert.deepEqual(calls, []);
  });

  it("refreshes the Initiatives list once it has been read", async () => {
    const domain = createDomainStore({
      initiativeTrees: { 12: tree(12, "Old") },
      initiativeSummaries: [summary(12, "Old")],
    });
    const { api, calls } = fakeApi({
      "/initiatives/12": tree(12, "New"),
      "/initiatives": [summary(12, "New")],
    });

    sync({ api, domain }).onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.deepEqual(calls, ["/initiatives/12", "/initiatives"]);
    assert.equal(domain.get().initiativeSummaries?.[0]?.name, "New");
  });

  it("never lets an older read land on top of a newer one", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
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

    assert.equal(domain.get().initiativeTrees[12]?.name, "Second");
  });

  it("leaves what it has alone when the re-read fails", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const { api } = fakeApi({});

    sync({ api, domain }).onChanged({ initiativeId: 12, kind: "task_deleted", id: 5 });
    await settle();

    assert.equal(domain.get().initiativeTrees[12]?.name, "Old");
  });
});

describe("what losing access makes the client do (item 1.5)", () => {
  it("a refetch still in flight cannot put back what a revocation removed", async () => {
    // The race: `changed` starts a read, access is taken away while it is out,
    // and the answer arrives last. It must be dropped, not written.
    const domain = createDomainStore({
      initiativeTrees: { 12: tree(12, "Old") },
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
    assert.equal(domain.get().initiativeTrees[12], undefined);
    assert.equal(forbidden, 1);

    fake.release(0);
    await settle();
    await settle();

    assert.equal(domain.get().initiativeTrees[12], undefined, "the stale read wrote it back");

    if (fake.parked() > 1) fake.release(1);
    await settle();
    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
    );
  });

  it("a list read in flight cannot put the row back either", async () => {
    // No tree held, so the handler goes straight to the index read — and that
    // read is the one carrying a row the user may no longer have.
    const domain = createDomainStore({
      initiativeSummaries: [summary(12, "Old"), summary(13, "Other")],
    });
    const ui = createUiStore({ route: { kind: "initiatives" } });
    const fake = fakeApi({ "/initiatives": [summary(12, "Old"), summary(13, "Other")] });
    fake.hold();

    const unit = sync({ api: fake.api, domain, ui });
    unit.onChanged({ initiativeId: 12, kind: "members_changed", id: 12 });
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

  it("lets a read begun after the revocation land (access given back)", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const ui = createUiStore({ route: { kind: "initiatives" } });
    const fake = fakeApi({ "/initiatives/12": tree(12, "Fresh") });

    const unit = sync({ api: fake.api, domain, ui });
    unit.onAccessRevoked(12);

    // The user is let back in, the screen reloads the tree, and a change lands.
    domain.set((state) => ({
      ...state,
      initiativeTrees: { ...state.initiativeTrees, 12: tree(12, "Old") },
    }));
    unit.onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.equal(domain.get().initiativeTrees[12]?.name, "Fresh");
  });

  it("forgets the Initiative, tree and index row alike", () => {
    const domain = createDomainStore({
      initiativeTrees: { 12: tree(12, "Gone"), 13: tree(13, "Kept") },
      initiativeSummaries: [summary(12, "Gone"), summary(13, "Kept")],
    });
    const ui = createUiStore({ route: { kind: "initiatives" } });

    sync({ domain, ui }).onAccessRevoked(12);

    assert.equal(domain.get().initiativeTrees[12], undefined);
    assert.equal(domain.get().initiativeTrees[13]?.name, "Kept");
    assert.deepEqual(
      domain.get().initiativeSummaries?.map((s) => s.id),
      [13],
    );
  });

  it("says so when the user is looking at it", () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Gone") } });
    const ui = createUiStore({ route: { kind: "initiative", id: 12 } });
    let forbidden = 0;

    sync({ domain, ui, onForbidden: () => (forbidden += 1) }).onAccessRevoked(12);

    assert.equal(forbidden, 1);
  });

  it("does not hijack the screen for an Initiative the user is not on", () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Gone") } });
    const ui = createUiStore({ route: { kind: "initiative", id: 13 } });
    let forbidden = 0;

    sync({ domain, ui, onForbidden: () => (forbidden += 1) }).onAccessRevoked(12);

    assert.equal(forbidden, 0);
    assert.equal(domain.get().initiativeTrees[12], undefined, "the copy still goes");
  });
});

describe("the local cache follows the same rules (items 3.4–3.6)", () => {
  it("caches a tree the guard let through", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const snapshots = fakeSnapshots();
    const backend = fakeApi({ "/initiatives/12": tree(12, "New") });

    sync({ api: backend.api, domain, snapshots }).onChanged({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.deepEqual(snapshots.cached, [12]);
  });

  it("deletes the snapshot when access is taken away", () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const snapshots = fakeSnapshots();

    sync({ domain, snapshots }).onAccessRevoked(12);

    assert.deepEqual(snapshots.forgotten, [12], "the copy on disk goes too (spec §12)");
  });

  it("does not cache a tree that arrived after access was taken away", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
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
