// What a queued operation leaves on the device, and how it comes back
// (m04.03 items 2.1, 2.3).
//
// The record is the INTENT, not the rendered batch: the intent is what a
// rebuilt prediction paints and what a later rebase re-runs. Once the batch has
// actually gone out its body is kept too, byte for byte, so a tab that dies
// mid-request comes back and resends exactly what the server may already have
// committed under exactly the same key — the server's idempotent replay does
// the rest. A record that was never sent (`queued`) builds its body fresh, from
// truth as it stands when it finally goes.
//
// Everything here is pure. `db.ts` stores the rows; `client_cache.ts` hands
// them out; the adapter writes and consumes them.

import type { Operation, TreeWrite } from "../tree/adapter.ts";
import type { PendingOpRecord } from "./db.ts";

/** The batch body exactly as `POST /operations` received it. */
export interface BatchBody {
  readonly operations: readonly Operation[];
}

/** What the user asked for: a tree write, or an undo/redo. */
export type PendingIntent =
  | { readonly kind: "write"; readonly write: TreeWrite }
  | { readonly kind: "history"; readonly action: "undo" | "redo" };

/**
 * `queued` — journaled, not yet sent; `body` is `null`. `sent` — the POST went
 * out at least once with `body`; the outcome may or may not be known.
 * `rejected` — the server refused it for a reason that will not change on its
 * own, and the user's content is kept for Retry or Discard (m04.03 4.6.2);
 * `body` is `null`, `reason` says why, and it is never replayed.
 */
export type PendingStatus = "queued" | "sent" | "rejected";

export type PendingPayload = PendingIntent & {
  readonly body: BatchBody | null;
  readonly status: PendingStatus;
  /** How many distinct bodies of this submission have been on the wire (m04.03 4.4's bound). */
  readonly attempts?: number;
  /** The refusal, in the words the pane shows. Only on `rejected`. */
  readonly reason?: string;
};

/** A stored operation whose payload has been read back and checked. */
export interface PendingOp {
  readonly key: string;
  readonly initiativeId: number;
  readonly createdAt: number;
  readonly payload: PendingPayload;
}

const WRITE_KINDS: ReadonlySet<string> = new Set([
  "add",
  "toggleComplete",
  "cascadeComplete",
  "reorder",
  "indent",
  "outdent",
  "move",
  "edit",
  "step",
  "coAssignees",
  "setSort",
  "cascadeSort",
  "delete",
]);

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function parseBody(value: unknown): BatchBody | null | undefined {
  if (value === null) return null;
  if (!isRecord(value) || !Array.isArray(value["operations"])) return undefined;
  for (const operation of value["operations"]) {
    if (!isRecord(operation)) return undefined;
    if (typeof operation["op"] !== "string" || typeof operation["type"] !== "string") return undefined;
    if (!isRecord(operation["data"])) return undefined;
  }
  return { operations: value["operations"] as Operation[] };
}

function parseWrite(value: unknown): TreeWrite | null {
  if (!isRecord(value) || typeof value["kind"] !== "string" || !WRITE_KINDS.has(value["kind"])) {
    return null;
  }
  if (value["kind"] === "add") {
    return isRecord(value["request"]) ? (value as unknown as TreeWrite) : null;
  }
  return typeof value["id"] === "number" ? (value as unknown as TreeWrite) : null;
}

/**
 * The payload as it was written, or `null` for anything else. Strict on the
 * envelope (kind, status, body) and on the shape of the intent; the intent's
 * own fields are the adapter's to judge when it rebuilds the batch.
 */
export function parsePendingPayload(value: unknown): PendingPayload | null {
  if (!isRecord(value)) return null;
  const status = value["status"];
  if (status !== "queued" && status !== "sent" && status !== "rejected") return null;
  const body = parseBody(value["body"]);
  if (body === undefined) return null;
  if (status === "sent" && body === null) return null;
  if (status === "rejected" && (body !== null || typeof value["reason"] !== "string")) return null;
  const attempts = value["attempts"];
  if (attempts !== undefined && (typeof attempts !== "number" || !Number.isInteger(attempts) || attempts < 0)) {
    return null;
  }
  const extras = {
    ...(typeof attempts === "number" ? { attempts } : {}),
    ...(status === "rejected" ? { reason: value["reason"] as string } : {}),
  };

  if (value["kind"] === "history") {
    const action = value["action"];
    if (action !== "undo" && action !== "redo") return null;
    return { kind: "history", action, body, status, ...extras };
  }
  if (value["kind"] === "write") {
    const write = parseWrite(value["write"]);
    if (write === null) return null;
    return { kind: "write", write, body, status, ...extras };
  }
  return null;
}

/** A stored row as a checked operation, or `null` when its payload is unreadable. */
export function parsePendingOp(record: PendingOpRecord): PendingOp | null {
  const payload = parsePendingPayload(record.payload);
  if (payload === null) return null;
  return {
    key: record.key,
    initiativeId: record.initiativeId,
    createdAt: record.createdAt,
    payload,
  };
}

/** Oldest first; ties broken by key so the order is the same on every boot. */
export function byCreation(a: PendingOp, b: PendingOp): number {
  return a.createdAt === b.createdAt ? (a.key < b.key ? -1 : a.key > b.key ? 1 : 0) : a.createdAt - b.createdAt;
}

/**
 * The records to replay for one Initiative, in creation order (item 2.3.1).
 * One record is one batch (2.3.2) — the plan never splits or merges them. A
 * `rejected` record is the user's to retry, never the plan's.
 */
export function replayPlan(records: readonly PendingOp[], initiativeId: number): PendingOp[] {
  return records
    .filter((record) => record.initiativeId === initiativeId && record.payload.status !== "rejected")
    .sort(byCreation);
}

/** The refused edits kept for one Initiative (m04.03 4.6.2), oldest first: the pane shows them again. */
export function rejectedRecords(records: readonly PendingOp[], initiativeId: number): PendingOp[] {
  return records
    .filter((record) => record.initiativeId === initiativeId && record.payload.status === "rejected")
    .sort(byCreation);
}
