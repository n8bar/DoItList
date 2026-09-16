import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import { createDomainStore } from "../state/domain.ts";
import { createChangedHandler } from "./refresh.ts";

const tree = (id: number, name: string): InitiativeTree =>
  ({ id, name, progress: 50, unit_count: 2, root: null }) as unknown as InitiativeTree;

const summary = (id: number, name: string): InitiativeSummary =>
  ({ id, name, progress: 50 }) as unknown as InitiativeSummary;

function fakeApi(responses: Record<string, unknown>) {
  const calls: string[] = [];
  const api = {
    get: <T,>(path: string): Promise<Result<T>> => {
      calls.push(path);
      const data = responses[path];
      return Promise.resolve(
        data === undefined
          ? { ok: false, error: { code: "not_found", status: 404, message: "gone" } }
          : { ok: true, data: data as T },
      );
    },
    post: () => Promise.reject(new Error("not used")),
    refreshSession: () => Promise.reject(new Error("not used")),
    csrfToken: () => "token",
  } as unknown as ApiClient;

  return { api, calls };
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

  it("leaves what it has alone when the re-read fails", async () => {
    const domain = createDomainStore({ initiativeTrees: { 12: tree(12, "Old") } });
    const { api } = fakeApi({});

    createChangedHandler({ api, domain })({ initiativeId: 12, kind: "task_deleted", id: 5 });
    await settle();

    assert.equal(domain.get().initiativeTrees[12]?.name, "Old");
  });
});
