// A server two clients can disagree through (m04.03 item 6.3).
//
// Test-only, but it lives beside the code it stands in for so the shapes stay
// in step: it answers `POST /operations` the way `DoItWeb.Api.Operations` does
// for the ops these scenarios use (an edit, a completion, a delete, a move, an
// add), assigns the Initiative's sequence per committed batch, keeps the
// idempotent response by key, applies each op to ONE canonical tree with the
// same pure ops the client predicts with, and fans one delta envelope per
// commit out to every client's inbox. Delivery is the test's: an inbox is
// drained when the test says, in the order the test says, and a reply can be
// held back so the broadcast reaches its own client first.

import type { ApiClient, ApiError, Result } from "../api/client.ts";
import type { InitiativeTree, TaskNode } from "../api/types.ts";
import type { BatchReply, Operation } from "../tree/adapter.ts";
import type { TaskRecord, TreeModel } from "../tree/model.ts";
import { childIdsOf, fromSnapshot } from "../tree/model.ts";
import { addTask, deleteSubtree, failed, moveTask, putRecord, setDone, updateFields } from "../tree/ops.ts";
import type { DeltaActor, DeltaEnvelope } from "./envelope.ts";

/** What one client sees of the server: its API handle and the envelopes waiting for it. */
export interface ServerClient {
  readonly name: string;
  readonly api: Pick<ApiClient, "get" | "post">;
  /** Envelopes committed and not yet delivered to this client, oldest first. */
  readonly inbox: DeltaEnvelope[];
  /** Every batch this client posted, in order, with the key it went under. */
  readonly posts: Array<{ key: string; body: { operations: Operation[] } }>;
  /** Replies to this client park until `releaseReplies`. */
  holdReplies(): void;
  releaseReplies(): void;
}

export interface FakeServer {
  canonical(): TreeModel;
  seq(): number;
  /** The tree as `GET /initiatives/:id` would answer it now. */
  snapshot(): InitiativeTree;
  client(name: string, userId: number): ServerClient;
}

const EDIT_FIELDS = ["title", "description", "priority", "assignee_id", "manual_progress"] as const;

const taskResult = (record: TaskRecord) => ({
  id: record.id,
  type: "task",
  title: record.title,
  parent_id: record.parent_id,
  status: record.status,
  done: record.done,
  progress: record.progress,
  manual_progress: record.manual_progress,
  priority: record.priority,
  assignee_id: record.assignee_id,
  updated_by: record.updated_by,
  updated_at: record.updated_at,
  version: record.version,
});

type OpOutcome =
  | { ok: true; model: TreeModel; data: unknown }
  | { ok: false; code: ApiError["code"]; status: number; message: string; pointer?: string; current?: TaskRecord };

/** The nested read, rebuilt from the flat model. */
export function toSnapshot(model: TreeModel): InitiativeTree {
  const node = (id: number): TaskNode => {
    const record = model.tasks[id] as TaskRecord;
    return { ...record, children: childIdsOf(model, id).map(node) };
  };
  return {
    id: model.initiativeId,
    name: model.header.name,
    subtitle: model.header.subtitle,
    role: model.header.role,
    progress: model.header.progress,
    progress_calc: model.progressCalc,
    unit_count: model.header.unit_count,
    index_style: model.indexStyle,
    root_task_id: model.rootId,
    version: model.header.version,
    seq: model.seq,
    tasks: childIdsOf(model, model.rootId).map(node),
  };
}

export function fakeServer(tree: InitiativeTree): FakeServer {
  let model = fromSnapshot(tree);
  let nextId = Math.max(0, ...Object.keys(model.tasks).map(Number)) + 1;
  const stored = new Map<string, { bytes: string; response: Result<BatchReply> }>();
  const inboxes = new Map<string, DeltaEnvelope[]>();

  const bump = (next: TreeModel, id: number): TreeModel => {
    const record = next.tasks[id];
    return record === undefined ? next : putRecord(next, { ...record, version: record.version + 1 });
  };

  const stale = (record: TaskRecord, data: Record<string, unknown>): OpOutcome | null => {
    const expected = data["expected_version"];
    if (expected === undefined || expected === record.version) return null;
    return {
      ok: false,
      code: "conflict",
      status: 409,
      message: `Task ${record.id} has changed since you read it.`,
      pointer: "expected_version",
      current: record,
    };
  };

  const missing = (id: number): OpOutcome => ({
    ok: false,
    code: "not_found",
    status: 404,
    message: `No such task with id ${id}.`,
  });

  const apply = (operation: Operation): OpOutcome => {
    const { op, type, id, data } = operation;
    if (type !== "task") return { ok: false, code: "unprocessable_entity", status: 422, message: "unsupported" };

    if (op === "add") {
      const parentId = typeof data["parent_id"] === "number" ? data["parent_id"] : model.rootId;
      const position = typeof data["position"] === "number" ? data["position"] : null;
      const created = nextId++;
      const result = addTask(model, { tempId: created, parentId, position, title: String(data["title"] ?? "") });
      if (failed(result)) return missing(parentId);
      const record = result.model.tasks[created] as TaskRecord;
      return { ok: true, model: result.model, data: taskResult(record) };
    }

    const record = id === undefined ? undefined : model.tasks[id];
    if (id === undefined || record === undefined) return missing(id ?? 0);
    const conflict = stale(record, data);
    if (conflict !== null) return conflict;

    if (op === "remove") {
      return { ok: true, model: deleteSubtree(model, id).model, data: { id, type: "task", deleted: true } };
    }

    let next: TreeModel;
    if ("done" in data) {
      next = setDone(model, id, data["done"] === true).model;
    } else if ("parent_id" in data || "position" in data || "reorder" in data) {
      const parentId = typeof data["parent_id"] === "number" ? data["parent_id"] : record.parent_id;
      const position = typeof data["position"] === "number" ? data["position"] : null;
      const moved = moveTask(model, { id, parentId, position, reorder: data["reorder"] === true });
      if (failed(moved)) {
        return moved.error === "cycle"
          ? { ok: false, code: "unprocessable_entity", status: 422, message: "A task can't be moved inside itself." }
          : missing(parentId);
      }
      next = moved.model;
    } else {
      const patch: Record<string, unknown> = {};
      for (const field of EDIT_FIELDS) if (field in data) patch[field] = data[field];
      next = updateFields(model, id, patch).model;
    }
    next = bump(next, id);
    return { ok: true, model: next, data: taskResult(next.tasks[id] as TaskRecord) };
  };

  /** The envelope for what `apply` changed: every record whose identity moved, and every id that left. */
  const envelopeFor = (before: TreeModel, after: TreeModel, originKey: string | null, actor: DeltaActor): DeltaEnvelope => {
    const upserts = Object.values(after.tasks).filter((record) => before.tasks[record.id] !== record);
    const removed = Object.keys(before.tasks)
      .map(Number)
      .filter((id) => after.tasks[id] === undefined);
    const header = after.header;
    const headerMoved =
      header !== before.header ||
      after.indexStyle !== before.indexStyle ||
      after.progressCalc !== before.progressCalc;
    return {
      initiativeId: after.initiativeId,
      seq: after.seq,
      originKey,
      actor,
      upserts,
      removed,
      initiative: headerMoved
        ? {
            version: header.version,
            name: header.name,
            subtitle: header.subtitle,
            progress: header.progress,
            unit_count: header.unit_count,
            progress_calc: after.progressCalc,
            index_style: after.indexStyle,
          }
        : null,
      membersChanged: false,
    };
  };

  const commit = (operations: Operation[], key: string | null, actor: DeltaActor): Result<BatchReply> => {
    const before = model;
    const results: BatchReply["results"] = [];
    for (const [index, operation] of operations.entries()) {
      const outcome = apply(operation);
      if (!outcome.ok) {
        model = before; // one failure rolls the batch back
        const error = {
          code: outcome.code,
          message: outcome.message,
          ...(outcome.pointer === undefined ? {} : { pointer: outcome.pointer }),
          ...(outcome.current === undefined ? {} : { current: outcome.current }),
        };
        return {
          ok: false,
          error: {
            code: outcome.code,
            status: outcome.status,
            message: outcome.message,
            payload: { error: { code: outcome.code, message: outcome.message }, results: [{ index, status: "error", error }] },
          },
        };
      }
      model = outcome.model;
      results.push({ index, status: "ok", data: outcome.data });
    }
    model = { ...model, seq: model.seq + 1 };
    const envelope = envelopeFor(before, model, key, actor);
    for (const inbox of inboxes.values()) inbox.push(envelope);
    return { ok: true, data: { results, seq: { [String(model.initiativeId)]: model.seq } } };
  };

  return {
    canonical: () => model,
    seq: () => model.seq,
    snapshot: () => toSnapshot(model),

    client(name, userId) {
      const inbox: DeltaEnvelope[] = [];
      inboxes.set(name, inbox);
      const posts: ServerClient["posts"] = [];
      const actor: DeltaActor = { id: userId, name, username: name.toLowerCase() };
      let holding = false;
      let parked: Array<() => void> = [];

      const answer = <T,>(value: Result<T>): Promise<Result<T>> =>
        holding ? new Promise((resolve) => parked.push(() => resolve(value))) : Promise.resolve(value);

      const api: Pick<ApiClient, "get" | "post"> = {
        get: <T,>(path: string): Promise<Result<T>> => {
          if (path !== `/initiatives/${model.initiativeId}`) {
            return answer({ ok: false, error: { code: "not_found", status: 404, message: "no such path" } });
          }
          return answer({ ok: true, data: toSnapshot(model) as unknown as T });
        },
        post: <T,>(_path: string, body: unknown, headers?: Record<string, string>): Promise<Result<T>> => {
          const key = headers?.["idempotency-key"] ?? null;
          const { operations } = body as { operations: Operation[] };
          posts.push({ key: key ?? "", body: { operations } });
          const bytes = JSON.stringify(operations);
          const held = key === null ? undefined : stored.get(key);
          let response: Result<BatchReply>;
          if (held !== undefined) {
            response =
              held.bytes === bytes
                ? held.response
                : {
                    ok: false,
                    error: { code: "unprocessable_entity", status: 422, message: "idempotency key reused with a different body" },
                  };
          } else {
            response = commit(operations, key, actor);
            if (key !== null && response.ok) stored.set(key, { bytes, response });
          }
          return answer(response as unknown as Result<T>);
        },
      };

      return {
        name,
        api,
        inbox,
        posts,
        holdReplies: () => {
          holding = true;
        },
        releaseReplies: () => {
          holding = false;
          const due = parked;
          parked = [];
          for (const go of due) go();
        },
      };
    },
  };
}
