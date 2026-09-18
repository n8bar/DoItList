import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { ApiClient, Result } from "../api/client.ts";
import type { BatchReply, Operation, TreeWrite } from "./adapter.ts";
import {
  changedFields,
  createAdapter,
  deltaFromReply,
  historyBatch,
  intentToBatch,
  rejectionMessage,
} from "./adapter.ts";
import type { TaskResult } from "./delta.ts";
import { applyDelta } from "./delta.ts";
import { buildTree } from "./gen.ts";
import { fromSnapshot } from "./model.ts";

// root 1: 10 Cabinets [11 Doors, 12 Handles, 13 Hinges], 20 Paint
const base = () =>
  fromSnapshot(
    buildTree(
      [
        {
          id: 10,
          title: "Cabinets",
          priority: "normal",
          children: [
            { id: 11, title: "Doors" },
            { id: 12, title: "Handles", priority: "high", assignee_id: 7 },
            { id: 13, title: "Hinges" },
          ],
        },
        { id: 20, title: "Paint" },
      ],
      { id: 5, rootTaskId: 1 },
    ),
  );

const batch = (write: TreeWrite, memberIds: number[] = [7, 8]) =>
  intentToBatch(write, { model: base(), memberIds });

const onlyOp = (write: TreeWrite, memberIds?: number[]): Operation => {
  const built = batch(write, memberIds);
  assert.equal(built.operations.length, 1);
  return built.operations[0]!;
};

const version = (id: number) => base().tasks[id]!.version;

describe("intentToBatch", () => {
  it("completion, either intent, is one done update", () => {
    assert.deepEqual(onlyOp({ kind: "toggleComplete", id: 11, done: true }), {
      op: "update",
      type: "task",
      id: 11,
      data: { done: true },
    });
    assert.deepEqual(onlyOp({ kind: "cascadeComplete", id: 10, done: false }).data, {
      done: false,
    });
    const built = batch({ kind: "cascadeComplete", id: 10, done: true });
    for (const id of [10, 11, 12, 13]) assert.ok(built.affectedIds.includes(id));
  });

  it("reorder computes the slot among the siblings and pins manual", () => {
    assert.deepEqual(onlyOp({ kind: "reorder", id: 12, dir: "up" }).data, {
      parent_id: 10,
      position: 0,
      reorder: true,
    });
    assert.deepEqual(onlyOp({ kind: "reorder", id: 12, dir: "down" }).data, {
      parent_id: 10,
      position: 2,
      reorder: true,
    });
  });

  it("a reorder with nowhere to go sends nothing", () => {
    assert.deepEqual(batch({ kind: "reorder", id: 11, dir: "up" }).operations, []);
    assert.deepEqual(batch({ kind: "reorder", id: 13, dir: "down" }).operations, []);
  });

  it("indent reparents under the previous sibling, no slot, no reorder flag", () => {
    assert.deepEqual(onlyOp({ kind: "indent", id: 12 }).data, { parent_id: 11 });
    assert.deepEqual(batch({ kind: "indent", id: 11 }).operations, []);
  });

  it("outdent lands right after the parent among the grand-siblings", () => {
    assert.deepEqual(onlyOp({ kind: "outdent", id: 12 }).data, { parent_id: 1, position: 1 });
    // Already top level: the parent is the root, which has no parent.
    assert.deepEqual(batch({ kind: "outdent", id: 20 }).operations, []);
  });

  it("move carries the drop's plan; a null position is omitted", () => {
    assert.deepEqual(
      onlyOp({ kind: "move", id: 20, parentId: 10, position: 1, reorder: true }).data,
      { parent_id: 10, position: 1, reorder: true },
    );
    assert.deepEqual(
      onlyOp({ kind: "move", id: 20, parentId: 10, position: null, reorder: false }).data,
      { parent_id: 10 },
    );
  });

  it("a move the model refuses sends nothing", () => {
    assert.deepEqual(
      batch({ kind: "move", id: 10, parentId: 11, position: null, reorder: false }).operations,
      [],
    );
  });

  it("edit sends the changed fields and the expected version", () => {
    const op = onlyOp({
      kind: "edit",
      id: 11,
      fields: { title: "Cabinet doors", priority: "normal", description: null },
    });
    assert.deepEqual(op.data, { title: "Cabinet doors", expected_version: version(11) });
  });

  it("an edit that changes nothing sends nothing", () => {
    const built = batch({ kind: "edit", id: 11, fields: { title: "Doors", priority: "normal" } });
    assert.deepEqual(built, { operations: [], affectedIds: [] });
  });

  it("step priority clamps at the ends and goes out as an edit", () => {
    assert.deepEqual(onlyOp({ kind: "step", id: 11, field: "priority", back: false }).data, {
      priority: "high",
      expected_version: version(11),
    });
    assert.deepEqual(onlyOp({ kind: "step", id: 11, field: "priority", back: true }).data, {
      priority: "low",
      expected_version: version(11),
    });
    // Already high: forward has nowhere to go.
    assert.deepEqual(batch({ kind: "step", id: 12, field: "priority", back: false }).operations, []);
  });

  it("step assignee cycles unassigned and the members, wrapping", () => {
    assert.equal(onlyOp({ kind: "step", id: 11, field: "assignee", back: false }).data["assignee_id"], 7);
    assert.equal(onlyOp({ kind: "step", id: 11, field: "assignee", back: true }).data["assignee_id"], 8);
    assert.equal(onlyOp({ kind: "step", id: 12, field: "assignee", back: false }).data["assignee_id"], 8);
    assert.equal(onlyOp({ kind: "step", id: 12, field: "assignee", back: true }).data["assignee_id"], null);
  });

  it("co-assignees, sort and cascade sort each send their one key", () => {
    assert.deepEqual(onlyOp({ kind: "coAssignees", id: 11, ids: [8, 7] }).data, {
      co_assignee_ids: [8, 7],
    });
    assert.deepEqual(onlyOp({ kind: "setSort", id: 10, mode: "alphabetical", reverse: true }).data, {
      sort_mode: "alphabetical",
      sort_reverse: true,
    });
    assert.deepEqual(onlyOp({ kind: "setSort", id: 10, mode: null, reverse: false }).data, {
      sort_mode: null,
      sort_reverse: false,
    });
    assert.deepEqual(onlyOp({ kind: "cascadeSort", id: 10 }).data, { cascade_sort: true });
  });

  it("delete is a remove guarded by the version, over the whole subtree", () => {
    const built = batch({ kind: "delete", id: 10 });
    assert.deepEqual(built.operations, [
      { op: "remove", type: "task", id: 10, data: { expected_version: version(10) } },
    ]);
    for (const id of [10, 11, 12, 13]) assert.ok(built.affectedIds.includes(id));
  });

  it("add under a task names the parent; add at the top names the Initiative", () => {
    assert.deepEqual(
      onlyOp({ kind: "add", request: { parentId: 10, position: 1, title: "Shelves" } }),
      {
        op: "add",
        type: "task",
        data: { initiative_id: 5, title: "Shelves", position: 1, parent_id: 10 },
      },
    );
    const top = batch({ kind: "add", request: { parentId: 1, position: 0, title: "Floor" } });
    assert.deepEqual(top.operations[0]?.data, { initiative_id: 5, title: "Floor", position: 0 });
    assert.ok(!top.affectedIds.includes(-1));
    assert.ok(top.affectedIds.includes(10));
  });

  it("an id the model does not hold sends nothing", () => {
    assert.deepEqual(batch({ kind: "toggleComplete", id: 99, done: true }).operations, []);
    assert.deepEqual(batch({ kind: "delete", id: 99 }).operations, []);
  });

  it("undo and redo are a history add on the Initiative", () => {
    assert.deepEqual(historyBatch(5, "undo").operations, [
      { op: "add", type: "history", data: { initiative_id: 5, action: "undo" } },
    ]);
    assert.equal(historyBatch(5, "redo").operations[0]?.data["action"], "redo");
  });
});

describe("changedFields", () => {
  const record = base().tasks[12]!;

  it("keeps only what differs", () => {
    assert.deepEqual(
      changedFields(record, { title: "Handles", priority: "low", assignee_id: 7, manual_progress: 40 }),
      { priority: "low", manual_progress: 40 },
    );
  });

  it("a null that matches a null is unchanged; a null that clears is a change", () => {
    assert.deepEqual(changedFields(record, { description: null }), {});
    assert.deepEqual(changedFields(record, { assignee_id: null }), { assignee_id: null });
  });

  it("nothing differs, nothing changed", () => {
    assert.deepEqual(changedFields(record, {}), {});
    assert.deepEqual(changedFields(record, { title: "Handles" }), {});
  });
});

const result = (over: Partial<TaskResult> = {}): TaskResult => ({
  id: 11,
  type: "task",
  title: "Doors",
  parent_id: 10,
  status: "open",
  done: false,
  progress: 0,
  manual_progress: 0,
  priority: "normal",
  assignee_id: null,
  version: 4,
  ...over,
});

describe("deltaFromReply", () => {
  it("an update result is one upsert", () => {
    const delta = deltaFromReply([], { results: [{ index: 0, status: "ok", data: result() }] });
    assert.equal(delta.upserts.length, 1);
    assert.equal(delta.upserts[0]?.id, 11);
    assert.deepEqual(delta.removed, []);
    assert.equal(delta.refetch, false);
  });

  it("a remove result is a removal, not an upsert", () => {
    const delta = deltaFromReply([], {
      results: [{ index: 0, status: "ok", data: { ...result(), deleted: true } }],
    });
    assert.deepEqual(delta.upserts, []);
    assert.deepEqual(delta.removed, [11]);
  });

  it("a sort result upserts every record with its sort pair", () => {
    const delta = deltaFromReply([], {
      results: [
        {
          index: 0,
          status: "ok",
          data: {
            id: 10,
            type: "task",
            records: [
              { ...result({ id: 10 }), sort_mode: "alphabetical", sort_reverse: true },
              { ...result({ id: 11 }), sort_mode: null, sort_reverse: false },
            ],
          },
        },
      ],
    });
    assert.deepEqual(
      delta.upserts.map((u) => [u.id, u.sort_mode, u.sort_reverse]),
      [
        [10, "alphabetical", true],
        [11, null, false],
      ],
    );
  });

  it("a co-assignee result carries the list; an add carries the requested slot", () => {
    const operations: Operation[] = [
      { op: "add", type: "task", data: { initiative_id: 5, title: "Shelves", position: 1, parent_id: 10 } },
      { op: "update", type: "task", id: 11, data: { co_assignee_ids: [8] } },
    ];
    const delta = deltaFromReply(operations, {
      results: [
        { index: 0, status: "ok", data: result({ id: 14, title: "Shelves" }) },
        { index: 1, status: "ok", data: { ...result(), co_assignee_ids: [8] } },
      ],
    });
    assert.equal(delta.upserts[0]?.position, 1);
    assert.deepEqual(delta.upserts[1]?.co_assignee_ids, [8]);
  });

  it("a move carries its slot: the one asked for, the top for a plain reparent, the end for a reorder with none", () => {
    const operations: Operation[] = [
      { op: "update", type: "task", id: 11, data: { parent_id: 10, position: 1, reorder: true } },
      { op: "update", type: "task", id: 12, data: { parent_id: 10 } },
      { op: "update", type: "task", id: 13, data: { parent_id: 10, reorder: true } },
      { op: "update", type: "task", id: 14, data: { title: "Not a move" } },
    ];
    const delta = deltaFromReply(operations, {
      results: [
        { index: 0, status: "ok", data: result({ id: 11 }) },
        { index: 1, status: "ok", data: result({ id: 12 }) },
        { index: 2, status: "ok", data: result({ id: 13 }) },
        { index: 3, status: "ok", data: result({ id: 14 }) },
      ],
    });
    assert.equal(delta.upserts[0]?.position, 1);
    assert.equal(delta.upserts[1]?.position, 0);
    assert.equal(delta.upserts[2]?.position, Number.MAX_SAFE_INTEGER);
    assert.equal(delta.upserts[3]?.position, undefined);
  });

  it("a history result is its own delta and carries refetch", () => {
    const delta = deltaFromReply([], {
      results: [
        {
          index: 0,
          status: "ok",
          data: {
            type: "history",
            action: "undo",
            kind: "commented",
            upserts: [{ ...result(), position: 2, description: "d" }],
            removed: [13],
            refetch: true,
          },
        },
      ],
    });
    assert.equal(delta.upserts[0]?.position, 2);
    assert.deepEqual(delta.removed, [13]);
    assert.equal(delta.refetch, true);
  });
});

describe("rejectionMessage", () => {
  it("prefers the offending op's message", () => {
    const message = rejectionMessage({
      code: "unprocessable_entity",
      status: 422,
      message: "Operation at index 1 failed; the batch was rolled back.",
      payload: {
        results: [
          { index: 0, status: "not_applied" },
          { index: 1, status: "error", error: { code: "unprocessable_entity", message: "title can't be blank" } },
        ],
      },
    });
    assert.equal(message, "title can't be blank");
  });

  it("falls back to the top-level message", () => {
    assert.equal(
      rejectionMessage({ code: "network", status: 0, message: "Failed to fetch" }),
      "Failed to fetch",
    );
  });
});

// --- the adapter ------------------------------------------------------------

interface Call {
  body: { operations: Operation[] };
  headers: Record<string, string> | undefined;
  resolve: (value: Result<BatchReply>) => void;
}

/** A fake `post` whose replies the test releases by hand, in any order. */
function fakeApi() {
  const calls: Call[] = [];
  const api = {
    post: <T,>(_path: string, body: unknown, headers?: Record<string, string>) =>
      new Promise<Result<T>>((resolve) => {
        calls.push({
          body: body as { operations: Operation[] },
          headers,
          resolve: resolve as (value: Result<BatchReply>) => void,
        });
      }),
  } as unknown as Pick<ApiClient, "post">;
  return { api, calls };
}

const okReply = (id: number): Result<BatchReply> => ({
  ok: true,
  data: { results: [{ index: 0, status: "ok", data: result({ id }) }] },
});

const networkError = (): Result<BatchReply> => ({
  ok: false,
  error: { code: "network", status: 0, message: "Failed to fetch" },
});

const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0));

function adapter(calls: ReturnType<typeof fakeApi>) {
  let n = 0;
  const submissions: string[] = [];
  const results: string[] = [];
  const model = base();
  const instance = createAdapter({
    api: calls.api,
    context: () => ({ model, memberIds: [7, 8] }),
    keyGen: () => `key-${++n}`,
    onSubmit: (s) => submissions.push(s.key),
    onResult: (s, r) => results.push(`${s.key}:${r.ok ? "ok" : r.error.code}`),
  });
  return { instance, submissions, results };
}

describe("createAdapter", () => {
  it("sends the batch under its key and answers with the delta", async () => {
    const fake = fakeApi();
    const { instance, submissions } = adapter(fake);

    const pending = instance.submit(5, { kind: "toggleComplete", id: 11, done: true });
    await settle();
    assert.equal(fake.calls.length, 1);
    assert.equal(fake.calls[0]?.headers?.["idempotency-key"], "key-1");
    assert.deepEqual(fake.calls[0]?.body.operations[0]?.data, { done: true });
    assert.deepEqual(submissions, ["key-1"]);

    fake.calls[0]?.resolve(okReply(11));
    const outcome = await pending;
    assert.ok(outcome.ok);
    assert.equal(outcome.delta.upserts[0]?.id, 11);
    assert.ok(outcome.affectedIds.includes(11));
  });

  it("per Initiative, one batch in flight; creation order is send order", async () => {
    const fake = fakeApi();
    const { instance, results } = adapter(fake);

    const first = instance.submit(5, { kind: "toggleComplete", id: 11, done: true });
    const second = instance.submit(5, { kind: "toggleComplete", id: 12, done: true });
    await settle();
    // The second waits for the first's reply.
    assert.equal(fake.calls.length, 1);
    assert.equal(fake.calls[0]?.body.operations[0]?.id, 11);

    fake.calls[0]?.resolve(okReply(11));
    await settle();
    assert.equal(fake.calls.length, 2);
    assert.equal(fake.calls[1]?.body.operations[0]?.id, 12);
    assert.equal(fake.calls[1]?.headers?.["idempotency-key"], "key-2");

    fake.calls[1]?.resolve(okReply(12));
    const [a, b] = await Promise.all([first, second]);
    assert.ok(a.ok && b.ok);
    assert.deepEqual(results, ["key-1:ok", "key-2:ok"]);
  });

  it("a second edit on one record is built at send time, with the bumped version", async () => {
    const fake = fakeApi();
    // The screen's canonical model: the first reply's version lands here.
    let canonical = base();
    let n = 0;
    const instance = createAdapter({
      api: fake.api,
      context: () => ({ model: canonical, memberIds: [7, 8] }),
      sendContext: () => ({ model: canonical, memberIds: [7, 8] }),
      keyGen: () => `key-${++n}`,
      onResult: (_s, r) => {
        if (r.ok) canonical = applyDelta(canonical, r.delta).model;
      },
    });

    const first = instance.submit(5, { kind: "edit", id: 11, fields: { title: "Door" } });
    const second = instance.submit(5, { kind: "edit", id: 11, fields: { priority: "high" } });
    await settle();
    assert.equal(fake.calls.length, 1);
    assert.equal(fake.calls[0]?.body.operations[0]?.data["expected_version"], version(11));

    fake.calls[0]?.resolve({
      ok: true,
      data: {
        results: [{ index: 0, status: "ok", data: result({ id: 11, title: "Door", version: version(11) + 1 }) }],
      },
    });
    await settle();
    assert.equal(fake.calls.length, 2);
    assert.deepEqual(fake.calls[1]?.body.operations[0]?.data, {
      priority: "high",
      expected_version: version(11) + 1,
    });

    fake.calls[1]?.resolve(okReply(11));
    const [a, b] = await Promise.all([first, second]);
    assert.ok(a.ok && b.ok);
  });

  it("a failure does not hold the queue; the next batch still goes", async () => {
    const fake = fakeApi();
    const { instance, results } = adapter(fake);

    const first = instance.submit(5, { kind: "delete", id: 11 });
    const second = instance.submit(5, { kind: "delete", id: 12 });
    await settle();
    fake.calls[0]?.resolve({
      ok: false,
      error: { code: "conflict", status: 409, message: "stale" },
    });
    const a = await first;
    assert.equal(a.ok, false);
    await settle();
    assert.equal(fake.calls.length, 2);
    fake.calls[1]?.resolve(okReply(12));
    const b = await second;
    assert.ok(b.ok);
    assert.deepEqual(results, ["key-1:conflict", "key-2:ok"]);
  });

  it("different Initiatives do not wait on each other", async () => {
    const fake = fakeApi();
    const { instance } = adapter(fake);

    void instance.submit(5, { kind: "toggleComplete", id: 11, done: true });
    void instance.submit(6, { kind: "toggleComplete", id: 12, done: true });
    await settle();
    assert.equal(fake.calls.length, 2);
  });

  it("a network failure retries the same key and payload once", async () => {
    const fake = fakeApi();
    const { instance } = adapter(fake);

    const pending = instance.submit(5, { kind: "toggleComplete", id: 11, done: true });
    await settle();
    fake.calls[0]?.resolve(networkError());
    await settle();
    assert.equal(fake.calls.length, 2);
    assert.equal(fake.calls[1]?.headers?.["idempotency-key"], "key-1");
    assert.deepEqual(fake.calls[1]?.body, fake.calls[0]?.body);

    fake.calls[1]?.resolve(okReply(11));
    const outcome = await pending;
    assert.ok(outcome.ok);
  });

  it("a second network failure is the answer", async () => {
    const fake = fakeApi();
    const { instance } = adapter(fake);

    const pending = instance.submit(5, { kind: "toggleComplete", id: 11, done: true });
    await settle();
    fake.calls[0]?.resolve(networkError());
    await settle();
    fake.calls[1]?.resolve(networkError());
    const outcome = await pending;
    assert.equal(outcome.ok, false);
    assert.ok(!outcome.ok && outcome.error.code === "network");
    assert.equal(fake.calls.length, 2);
  });

  it("a rejection other than network is not retried", async () => {
    const fake = fakeApi();
    const { instance } = adapter(fake);

    const pending = instance.submit(5, { kind: "toggleComplete", id: 11, done: true });
    await settle();
    fake.calls[0]?.resolve({
      ok: false,
      error: { code: "forbidden", status: 403, message: "no" },
    });
    const outcome = await pending;
    assert.equal(outcome.ok, false);
    assert.equal(fake.calls.length, 1);
  });

  it("an empty batch sends nothing and uses no key", async () => {
    const fake = fakeApi();
    const { instance, submissions } = adapter(fake);

    const outcome = await instance.submit(5, {
      kind: "edit",
      id: 11,
      fields: { title: "Doors" },
    });
    assert.ok(outcome.ok);
    assert.deepEqual(outcome.affectedIds, []);
    assert.equal(fake.calls.length, 0);
    assert.deepEqual(submissions, []);
  });

  it("undo and redo go through the same queue", async () => {
    const fake = fakeApi();
    const { instance } = adapter(fake);

    const pending = instance.submitHistory(5, "undo");
    await settle();
    assert.deepEqual(fake.calls[0]?.body.operations, [
      { op: "add", type: "history", data: { initiative_id: 5, action: "undo" } },
    ]);
    fake.calls[0]?.resolve({
      ok: true,
      data: {
        results: [
          {
            index: 0,
            status: "ok",
            data: {
              type: "history",
              action: "undo",
              kind: "child_deleted",
              upserts: [{ ...result({ id: 13 }), position: 2, description: null }],
              removed: [],
              refetch: false,
            },
          },
        ],
      },
    });
    const outcome = await pending;
    assert.ok(outcome.ok);
    assert.equal(outcome.delta.upserts[0]?.id, 13);
    assert.equal(outcome.delta.upserts[0]?.position, 2);
  });
});
