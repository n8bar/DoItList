import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import { createDomainStore } from "../state/domain.ts";
import { createUiStore } from "../state/ui.ts";
import { createChangedHandler, createRevokedHandler } from "./refresh.ts";

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

describe("what a `changed` event makes the client do (item 1.5)", () => {
  it("re-reads the Initiative it is holding", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const { api, calls } = fakeApi({ "/initiatives/12": tree(12, "New") });

    createChangedHandler({ api, domain })({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.deepEqual(calls, ["/initiatives/12"]);
    assert.equal(domain.get().initiativeTrees[12]?.name, "New");
  });

  it("does not fetch a tree the tab is not holding", async () => {
    const domain = createDomainStore();
    const { api, calls } = fakeApi({ "/initiatives/12": tree(12, "New") });

    createChangedHandler({ api, domain })({ initiativeId: 12, kind: "task_moved", id: 5 });
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

    createChangedHandler({ api, domain })({ initiativeId: 12, kind: "task_updated", id: 5 });
    await settle();

    assert.deepEqual(calls, ["/initiatives/12", "/initiatives"]);
    assert.equal(domain.get().initiativeSummaries?.[0]?.name, "New");
  });

  it("never lets an older read land on top of a newer one", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const fake = fakeApi({});
    fake.answers("/initiatives/12", [tree(12, "First"), tree(12, "Second")]);
    fake.hold();

    const onChanged = createChangedHandler({ api: fake.api, domain });
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

    createChangedHandler({ api, domain })({ initiativeId: 12, kind: "task_deleted", id: 5 });
    await settle();

    assert.equal(domain.get().initiativeTrees[12]?.name, "Old");
  });
});

describe("what losing access makes the client do (item 1.5)", () => {
  it("forgets the Initiative, tree and index row alike", () => {
    const domain = createDomainStore({
      initiativeTrees: { 12: tree(12, "Gone"), 13: tree(13, "Kept") },
      initiativeSummaries: [summary(12, "Gone"), summary(13, "Kept")],
    });
    const ui = createUiStore({ route: { kind: "initiatives" } });

    createRevokedHandler({ domain, ui, onForbidden: () => {} })(12);

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

    createRevokedHandler({ domain, ui, onForbidden: () => (forbidden += 1) })(12);

    assert.equal(forbidden, 1);
  });

  it("does not hijack the screen for an Initiative the user is not on", () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Gone") } });
    const ui = createUiStore({ route: { kind: "initiative", id: 13 } });
    let forbidden = 0;

    createRevokedHandler({ domain, ui, onForbidden: () => (forbidden += 1) })(12);

    assert.equal(forbidden, 0);
    assert.equal(domain.get().initiativeTrees[12], undefined, "the copy still goes");
  });
});
