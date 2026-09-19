import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { TreeWrite } from "../tree/adapter.ts";
import type { PendingOp } from "./pending_ops.ts";
import { parsePendingOp, parsePendingPayload, rejectedRecords, replayPlan } from "./pending_ops.ts";

const write: TreeWrite = { kind: "toggleComplete", id: 11, done: true };
const body = { operations: [{ op: "update", type: "task", id: 11, data: { done: true } }] };

const op = (key: string, initiativeId: number, createdAt: number): PendingOp => ({
  key,
  initiativeId,
  createdAt,
  payload: { kind: "write", write, body: null, status: "queued" },
});

describe("a queued operation's payload (m04.03 2.1)", () => {
  it("reads back a queued write and a sent one with its body", () => {
    assert.deepEqual(parsePendingPayload({ kind: "write", write, body: null, status: "queued" }), {
      kind: "write",
      write,
      body: null,
      status: "queued",
    });
    assert.deepEqual(parsePendingPayload({ kind: "write", write, body, status: "sent" }), {
      kind: "write",
      write,
      body,
      status: "sent",
    });
    assert.deepEqual(parsePendingPayload({ kind: "history", action: "undo", body: null, status: "queued" }), {
      kind: "history",
      action: "undo",
      body: null,
      status: "queued",
    });
  });

  it("refuses anything it did not write", () => {
    assert.equal(parsePendingPayload(null), null);
    assert.equal(parsePendingPayload("complete"), null);
    assert.equal(parsePendingPayload({ kind: "complete" }), null);
    assert.equal(parsePendingPayload({ kind: "write", write, body: null, status: "done" }), null);
    assert.equal(parsePendingPayload({ kind: "write", write: { kind: "explode", id: 1 }, body: null, status: "queued" }), null);
    assert.equal(parsePendingPayload({ kind: "write", write: { kind: "edit" }, body: null, status: "queued" }), null);
    assert.equal(parsePendingPayload({ kind: "history", action: "again", body: null, status: "queued" }), null);
    // A sent record without its body cannot be resent as it was.
    assert.equal(parsePendingPayload({ kind: "write", write, body: null, status: "sent" }), null);
    assert.equal(parsePendingPayload({ kind: "write", write, body: { operations: "many" }, status: "sent" }), null);
    assert.equal(parsePendingPayload({ kind: "write", write, body: { operations: [{ op: "update" }] }, status: "sent" }), null);
  });

  it("reads a stored row, or refuses the whole row when the payload is bad", () => {
    const row = { key: "k", initiativeId: 5, createdAt: 9, payload: { kind: "write", write, body: null, status: "queued" } };
    assert.equal(parsePendingOp(row)?.key, "k");
    assert.equal(parsePendingOp({ ...row, payload: { kind: "nope" } }), null);
  });
});

describe("the replay plan (m04.03 2.3.1, 2.3.2)", () => {
  it("is this Initiative's records only, oldest first, one record each", () => {
    const plan = replayPlan([op("c", 5, 30), op("x", 6, 5), op("a", 5, 10), op("b", 5, 20)], 5);
    assert.deepEqual(
      plan.map((record) => record.key),
      ["a", "b", "c"],
    );
  });

  it("breaks a tie on the key, so every boot replays in the same order", () => {
    const plan = replayPlan([op("b", 5, 10), op("a", 5, 10)], 5);
    assert.deepEqual(
      plan.map((record) => record.key),
      ["a", "b"],
    );
  });
});

describe("a refused write kept for the user (m04.03 4.4, 4.6.2)", () => {
  const rejected = { kind: "write", write, body: null, status: "rejected", reason: "Someone else kept changing this.", attempts: 3 };

  it("reads back with its reason and its count", () => {
    assert.deepEqual(parsePendingPayload(rejected), { ...rejected });
    assert.deepEqual(parsePendingPayload({ kind: "write", write, body: null, status: "queued", attempts: 0 })?.attempts, 0);
  });

  it("refuses a rejected row with bytes or without a reason, and a count that is not one", () => {
    assert.equal(parsePendingPayload({ ...rejected, body }), null);
    assert.equal(parsePendingPayload({ ...rejected, reason: undefined }), null);
    assert.equal(parsePendingPayload({ kind: "write", write, body: null, status: "queued", attempts: -1 }), null);
    assert.equal(parsePendingPayload({ kind: "write", write, body: null, status: "queued", attempts: 1.5 }), null);
  });

  it("is never in the replay plan; rejectedRecords lists it, for this Initiative, oldest first", () => {
    const held = (key: string, initiativeId: number, createdAt: number): PendingOp => ({
      key,
      initiativeId,
      createdAt,
      payload: { kind: "write", write, body: null, status: "rejected", reason: "no" },
    });
    const records = [held("r2", 5, 20), op("a", 5, 10), held("r1", 5, 15), held("x", 6, 1)];
    assert.deepEqual(
      replayPlan(records, 5).map((record) => record.key),
      ["a"],
    );
    assert.deepEqual(
      rejectedRecords(records, 5).map((record) => record.key),
      ["r1", "r2"],
    );
  });
});
