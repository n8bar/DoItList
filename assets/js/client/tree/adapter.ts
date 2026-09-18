// The operation adapter (m04.02 items 5.1.1, 5.1.3).
//
// Every write the tree asks for goes out through here and nowhere else. One
// intent becomes ONE batch for `POST /app/api/operations` — the same atomic
// shape an agent sends — under a generated `Idempotency-Key`, so a retry of a
// lost reply replays the stored result instead of applying the batch twice.
//
// Per Initiative, batches leave in the order they were created and one at a
// time: the second waits for the first's reply, so the server sees the user's
// actions in the order the user took them and a later op never lands on a
// record an earlier one is still changing. A batch is BUILT when it is
// dequeued, not when it is queued: `expected_version` and slots come from the
// canonical model as the previous reply left it, so two edits queued on one
// record do not both carry the version the first one is about to bump.
//
// The server stays authoritative. What comes back is turned into a `TreeDelta`
// (`delta.ts`) and handed to the caller; the pure ops in `ops.ts` are used here
// to work out WHICH records a write touches (`affectedIds`, the scope item 5.2
// paints pending), what the write will most likely look like (`predictWrite`,
// the display-only guess `optimistic.ts` folds over canonical) and, for a
// keyboard move, the slot the server op needs. Nothing here paints, reverts,
// or reconciles.

import type { ApiClient, ApiError } from "../api/client.ts";
import type { Priority } from "../api/types.ts";
import type { AddRequest } from "./add_form_model.ts";
import type { TreeIntent } from "./context.ts";
import type { HistoryResult, TaskResult, TaskUpsert, TreeDelta } from "./delta.ts";
import { deltaFromHistoryResult, deltaFromOpResult } from "./delta.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { childIdsOf } from "./model.ts";
import type { MoveArgs, OpResult } from "./ops.ts";
import {
  addTask,
  cascadeSort,
  deleteSubtree,
  failed,
  moveTask,
  setDone,
  setSort,
  updateFields,
} from "./ops.ts";

/** A write the tree can ask for: an intent, or the add form's submission. */
export type TreeWrite = TreeIntent | { kind: "add"; request: AddRequest };

/** One op on the wire, as `DoItWeb.Api.Operations` reads it. */
export interface Operation {
  op: "add" | "update" | "remove";
  type: "task" | "history";
  id?: number;
  data: Record<string, unknown>;
}

export interface Batch {
  operations: Operation[];
  /** The records whose display this write may change, from the pure ops. */
  affectedIds: number[];
}

export interface BatchContext {
  model: TreeModel;
  /** Member user ids in display order — what the A key steps through. */
  memberIds?: readonly number[];
}

const EMPTY: Batch = { operations: [], affectedIds: [] };

/** Low → normal → high; a step forward moves toward high, clamped (no wrap). */
const PRIORITY_ORDER: readonly Priority[] = ["low", "normal", "high"];

/** The fields an edit may carry, in the order the server lists them. */
const EDIT_FIELDS = ["title", "description", "priority", "assignee_id", "manual_progress"] as const;
type EditField = (typeof EDIT_FIELDS)[number];

/**
 * One write, one batch. A write the model cannot make (an id it does not hold,
 * a move with nowhere to go, an edit that changes nothing) is an empty batch:
 * nothing is sent, and the caller sees an immediate empty success.
 */
export function intentToBatch(write: TreeWrite, context: BatchContext): Batch {
  const { model } = context;

  switch (write.kind) {
    case "add":
      return addBatch(model, write.request);

    case "toggleComplete":
    case "cascadeComplete": {
      // The engine's `done` always cascades (`Tasks.cascade_complete/2`); on a
      // leaf that is the plain flip. Which confirm opens is item 5.1.4's call.
      if (model.tasks[write.id] === undefined) return EMPTY;
      return one(
        update(write.id, { done: write.done }),
        setDone(model, write.id, write.done).affected,
      );
    }

    case "reorder":
    case "indent":
    case "outdent":
    case "move": {
      const args = moveArgsFor(model, write);
      if (args === null) return EMPTY;
      return moveBatch(model, args.id, args.parentId, args.position ?? null, args.reorder === true);
    }

    case "edit":
      return editBatch(model, write.id, write.fields);

    case "step": {
      const record = model.tasks[write.id];
      if (record === undefined) return EMPTY;
      return editBatch(model, write.id, stepped(record, write.field, write.back, context));
    }

    case "coAssignees":
      if (model.tasks[write.id] === undefined) return EMPTY;
      return one(
        update(write.id, { co_assignee_ids: [...write.ids] }),
        updateFields(model, write.id, { co_assignee_ids: write.ids }).affected,
      );

    case "setSort":
      if (model.tasks[write.id] === undefined) return EMPTY;
      return one(
        update(write.id, { sort_mode: write.mode, sort_reverse: write.reverse }),
        setSort(model, write.id, write.mode, write.reverse).affected,
      );

    case "cascadeSort":
      if (model.tasks[write.id] === undefined) return EMPTY;
      return one(
        update(write.id, { cascade_sort: true }),
        cascadeSort(model, write.id).affected,
      );

    case "delete": {
      const record = model.tasks[write.id];
      if (record === undefined) return EMPTY;
      return one(
        { op: "remove", type: "task", id: write.id, data: { expected_version: record.version } },
        deleteSubtree(model, write.id).affected,
      );
    }

    default:
      return EMPTY;
  }
}

/**
 * What the model most likely looks like once `write` lands — the same pure op
 * `intentToBatch` consulted, run for its model this time. `null` when there is
 * nothing to predict (nothing would be sent). An add's new row gets `tempId`;
 * the caller owns making it unique across the adds it has in flight.
 */
export function predictWrite(
  write: TreeWrite,
  context: BatchContext,
  tempId: number,
): TreeModel | null {
  const { model } = context;

  switch (write.kind) {
    case "add": {
      const predicted = addTask(model, {
        tempId,
        parentId: write.request.parentId,
        position: write.request.position,
        title: write.request.title,
      });
      return failed(predicted) ? null : predicted.model;
    }

    case "toggleComplete":
    case "cascadeComplete":
      return changed(setDone(model, write.id, write.done));

    case "reorder":
    case "indent":
    case "outdent":
    case "move": {
      const args = moveArgsFor(model, write);
      if (args === null) return null;
      const predicted = moveTask(model, args);
      return failed(predicted) ? null : predicted.model;
    }

    case "edit":
      return changed(updateFields(model, write.id, changedFor(model, write.id, write.fields)));

    case "step": {
      const record = model.tasks[write.id];
      if (record === undefined) return null;
      const fields = changedFields(record, stepped(record, write.field, write.back, context));
      return changed(updateFields(model, write.id, fields));
    }

    case "coAssignees":
      return changed(updateFields(model, write.id, { co_assignee_ids: write.ids }));

    case "setSort":
      return changed(setSort(model, write.id, write.mode, write.reverse));

    case "cascadeSort":
      return changed(cascadeSort(model, write.id));

    case "delete":
      return changed(deleteSubtree(model, write.id));

    default:
      return null;
  }
}

/** The record the write is about — what item 5.2 paints as saving. */
export function targetOf(write: TreeWrite, tempId: number): number {
  return write.kind === "add" ? tempId : write.id;
}

function changed(result: OpResult): TreeModel | null {
  return result.affected.length === 0 ? null : result.model;
}

function changedFor(
  model: TreeModel,
  id: number,
  fields: Partial<Pick<TaskRecord, EditField>>,
): Partial<Pick<TaskRecord, EditField>> {
  const record = model.tasks[id];
  return record === undefined ? {} : changedFields(record, fields);
}

/**
 * The slot a keyboard or drag move lands in, as `moveTask` reads it — shared
 * with the confirm (`confirm_model.ts`) so the flip it predicts is the move that
 * is sent. `null` when there is nowhere to go.
 */
export function moveArgsFor(
  model: TreeModel,
  write: Extract<TreeWrite, { kind: "reorder" | "indent" | "outdent" | "move" }>,
): MoveArgs | null {
  const record = model.tasks[write.id];
  if (record === undefined) return null;

  switch (write.kind) {
    case "reorder": {
      const siblings = childIdsOf(model, record.parent_id);
      const at = siblings.indexOf(write.id);
      const position = write.dir === "up" ? at - 1 : at + 1;
      if (at === -1 || position < 0 || position >= siblings.length) return null;
      return { id: write.id, parentId: record.parent_id, position, reorder: true };
    }

    case "indent": {
      // Alt+→: first child of the previous sibling (`kbd_indent/3`). A plain
      // reparent with no slot lands at the top of the new parent.
      const siblings = childIdsOf(model, record.parent_id);
      const previous = siblings[siblings.indexOf(write.id) - 1];
      if (previous === undefined) return null;
      return { id: write.id, parentId: previous, position: null };
    }

    case "outdent": {
      // Alt+←: a sibling of the parent, right after it (`kbd_dedent/1`).
      const parent = model.tasks[record.parent_id];
      if (parent === undefined) return null;
      const grandSiblings = childIdsOf(model, parent.parent_id);
      return { id: write.id, parentId: parent.parent_id, position: grandSiblings.indexOf(parent.id) + 1 };
    }

    case "move":
      return { id: write.id, parentId: write.parentId, position: write.position, reorder: write.reorder };
  }
}

/** The undo/redo batch: `add history` on the Initiative's shared stack. */
export function historyBatch(initiativeId: number, action: "undo" | "redo"): Batch {
  return {
    operations: [{ op: "add", type: "history", data: { initiative_id: initiativeId, action } }],
    affectedIds: [],
  };
}

/**
 * Only the fields that differ from the record, plus its `expected_version`
 * (item 5.1.3). A diff that leaves nothing is nothing to send.
 */
export function changedFields(
  record: TaskRecord,
  fields: Partial<Pick<TaskRecord, EditField>>,
): Partial<Pick<TaskRecord, EditField>> {
  const changed: Partial<Pick<TaskRecord, EditField>> = {};
  for (const field of EDIT_FIELDS) {
    const value = fields[field];
    if (value === undefined || value === record[field]) continue;
    (changed as Record<string, unknown>)[field] = value;
  }
  return changed;
}

function editBatch(
  model: TreeModel,
  id: number,
  fields: Partial<Pick<TaskRecord, EditField>>,
): Batch {
  const record = model.tasks[id];
  if (record === undefined) return EMPTY;
  const changed = changedFields(record, fields);
  if (Object.keys(changed).length === 0) return EMPTY;
  return one(
    update(id, { ...changed, expected_version: record.version }),
    updateFields(model, id, changed).affected,
  );
}

// P / A: the next value, as `step_priority/2` / `step_assignee/3` compute it —
// priority clamps at both ends, assignee cycles [Unassigned | members…].
function stepped(
  record: TaskRecord,
  field: "priority" | "assignee",
  back: boolean,
  context: BatchContext,
): Partial<Pick<TaskRecord, EditField>> {
  const step = back ? -1 : 1;
  if (field === "priority") {
    const at = Math.max(0, PRIORITY_ORDER.indexOf(record.priority));
    const next = Math.max(0, Math.min(at + step, PRIORITY_ORDER.length - 1));
    return { priority: PRIORITY_ORDER[next] ?? record.priority };
  }
  const ids: (number | null)[] = [null, ...(context.memberIds ?? [])];
  const at = Math.max(0, ids.indexOf(record.assignee_id));
  const next = (at + step + ids.length) % ids.length;
  return { assignee_id: ids[next] ?? null };
}

function moveBatch(
  model: TreeModel,
  id: number,
  parentId: number,
  position: number | null,
  reorder: boolean,
): Batch {
  const predicted = moveTask(model, { id, parentId, position, reorder });
  if (failed(predicted)) return EMPTY;
  const data: Record<string, unknown> = { parent_id: parentId };
  if (position !== null) data["position"] = position;
  if (reorder) data["reorder"] = true;
  return one(update(id, data), predicted.affected);
}

function addBatch(model: TreeModel, request: AddRequest): Batch {
  const predicted = addTask(model, {
    tempId: -1,
    parentId: request.parentId,
    position: request.position,
    title: request.title,
  });
  if (failed(predicted)) return EMPTY;
  const data: Record<string, unknown> = {
    initiative_id: model.initiativeId,
    title: request.title,
    position: request.position,
  };
  // The root is the Initiative's own system task; naming the Initiative alone
  // is how the engine spells "top level".
  if (request.parentId !== model.rootId) data["parent_id"] = request.parentId;
  return one(
    { op: "add", type: "task", data },
    predicted.affected.filter((affectedId) => affectedId !== -1),
  );
}

function update(id: number, data: Record<string, unknown>): Operation {
  return { op: "update", type: "task", id, data };
}

function one(operation: Operation, affectedIds: number[]): Batch {
  return { operations: [operation], affectedIds };
}

// --- the reply --------------------------------------------------------------

/** What the server answers a batch with (`DoItWeb.Api.OperationsEndpoint`). */
export interface BatchReply {
  results: Array<{ index: number; status: string; data?: unknown }>;
}

/** The sort concern's result: the target and every branch the cascade re-sorted. */
interface SortResult {
  id: number;
  type: "task";
  records: Array<TaskResult & { sort_mode: TaskRecord["sort_mode"]; sort_reverse: boolean }>;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/**
 * A reply as one delta. Each result's shape says what it is: a history result
 * carries its own upserts and removals; a remove is a removal; a sort result
 * carries `records`; everything else is the `task_result/1` shape. An add's
 * result has no `position`, so the requested slot is carried over — the server
 * honored it, and the row should land where the user put it.
 */
export function deltaFromReply(operations: readonly Operation[], reply: BatchReply): TreeDelta & {
  refetch: boolean;
} {
  const upserts: TaskUpsert[] = [];
  const removed: number[] = [];
  let refetch = false;

  for (const result of reply.results) {
    const data = result.data;
    if (!isRecord(data)) continue;
    const operation = operations[result.index];

    if (data["type"] === "history") {
      const delta = deltaFromHistoryResult(data as unknown as HistoryResult);
      upserts.push(...delta.upserts);
      removed.push(...delta.removed);
      refetch = refetch || (data as unknown as HistoryResult).refetch === true;
      continue;
    }

    if (data["deleted"] === true) {
      removed.push(data["id"] as number);
      continue;
    }

    if (Array.isArray(data["records"])) {
      for (const record of (data as unknown as SortResult).records) {
        upserts.push({
          ...deltaFromOpResult(record).upserts[0]!,
          sort_mode: record.sort_mode,
          sort_reverse: record.sort_reverse,
        });
      }
      continue;
    }

    const upsert = deltaFromOpResult(data as unknown as TaskResult).upserts[0]!;
    if (Array.isArray(data["co_assignee_ids"])) {
      upsert.co_assignee_ids = data["co_assignee_ids"] as number[];
    }
    const slot = requestedSlot(operation);
    if (slot !== undefined) upsert.position = slot;
    upserts.push(upsert);
  }

  return { upserts, removed, refetch };
}

/** Past any sibling list: `applyDelta` clamps it to the end. */
const END_SLOT = Number.MAX_SAFE_INTEGER;

/**
 * The slot an add or a move asked for. The server honors it and its result
 * does not repeat it, so without this the canonical model would fall back to
 * the old order until the refetch — a flicker the user would see. A reparent
 * with no slot lands at the top; a reorder with none (a bottom zone) appends.
 */
function requestedSlot(operation: Operation | undefined): number | undefined {
  if (operation === undefined || operation.type !== "task") return undefined;
  const { data } = operation;
  const move =
    operation.op === "update" && ("parent_id" in data || "position" in data || "reorder" in data);
  if (operation.op !== "add" && !move) return undefined;
  if (typeof data["position"] === "number") return data["position"];
  if (!move) return undefined;
  return data["reorder"] === true ? END_SLOT : 0;
}

/**
 * The sentence to show for a rejected batch: the offending op's own message
 * when the reply names one, else the top-level one.
 */
export function rejectionMessage(error: ApiError): string {
  const payload = error.payload;
  if (isRecord(payload) && Array.isArray(payload["results"])) {
    for (const result of payload["results"]) {
      if (!isRecord(result) || !isRecord(result["error"])) continue;
      const message = result["error"]["message"];
      if (typeof message === "string" && message !== "") return message;
    }
  }
  return error.message;
}

// --- the adapter ------------------------------------------------------------

export type SubmitResult =
  | { ok: true; delta: TreeDelta; refetch: boolean; affectedIds: number[] }
  | { ok: false; error: ApiError; affectedIds: number[] };

/** What a submission looks like the moment it is queued — item 5.2's pending scope. */
export interface Submission {
  key: string;
  initiativeId: number;
  affectedIds: number[];
  /** The write this batch carries; `null` for undo/redo. */
  write: TreeWrite | null;
}

export interface AdapterOptions {
  api: Pick<ApiClient, "post">;
  /**
   * The model as shown and the members for an Initiative; `undefined` if not
   * loaded. Consulted as a write is queued, for what it touches.
   */
  context: (initiativeId: number) => BatchContext | undefined;
  /**
   * The canonical model — no predictions — the batch is built from as it is
   * sent. Defaults to `context`.
   */
  sendContext?: (initiativeId: number) => BatchContext | undefined;
  /** Injected in tests; defaults to `crypto.randomUUID()`. */
  keyGen?: () => string;
  /** Fires synchronously as a batch is queued, before anything is sent. */
  onSubmit?: (submission: Submission) => void;
  /** Fires with the outcome of each queued batch, in order per Initiative. */
  onResult?: (submission: Submission, result: SubmitResult) => void;
}

export interface OperationAdapter {
  submit(initiativeId: number, write: TreeWrite): Promise<SubmitResult>;
  submitHistory(initiativeId: number, action: "undo" | "redo"): Promise<SubmitResult>;
}

export function createAdapter(options: AdapterOptions): OperationAdapter {
  const keyGen = options.keyGen ?? (() => crypto.randomUUID());
  // The tail of each Initiative's queue. A batch is chained onto it at submit
  // time, so creation order is send order and only one is ever in flight.
  const tails = new Map<number, Promise<unknown>>();

  const emptyOk = (affectedIds: number[]): SubmitResult => ({
    ok: true,
    delta: { upserts: [], removed: [] },
    refetch: false,
    affectedIds,
  });

  async function send(
    submission: Submission,
    build: (context: BatchContext) => Batch,
  ): Promise<SubmitResult> {
    // Built now, from truth as the previous reply left it.
    const context = (options.sendContext ?? options.context)(submission.initiativeId);
    const operations = context === undefined ? [] : build(context).operations;
    if (operations.length === 0) return emptyOk(submission.affectedIds);

    const body = { operations };
    const headers = { "idempotency-key": submission.key };
    let result = await options.api.post<BatchReply>("/operations", body, headers);
    // A reply that never arrived: the same key replays a commit the server did
    // make, and re-runs one it did not. Once — a link that is down stays down.
    if (!result.ok && result.error.code === "network") {
      result = await options.api.post<BatchReply>("/operations", body, headers);
    }
    if (!result.ok) return { ok: false, error: result.error, affectedIds: submission.affectedIds };
    const { refetch, ...delta } = deltaFromReply(operations, result.data);
    return { ok: true, delta, refetch, affectedIds: submission.affectedIds };
  }

  function queue(
    initiativeId: number,
    build: (context: BatchContext) => Batch,
    write: TreeWrite | null,
  ): Promise<SubmitResult> {
    // Against what is shown, for whether anything would go and what it touches.
    const context = options.context(initiativeId);
    const preview = context === undefined ? EMPTY : build(context);
    if (preview.operations.length === 0) return Promise.resolve(emptyOk([]));

    const submission: Submission = {
      key: keyGen(),
      initiativeId,
      affectedIds: preview.affectedIds,
      write,
    };
    options.onSubmit?.(submission);

    const previous = tails.get(initiativeId) ?? Promise.resolve();
    const run = previous
      .then(() => send(submission, build))
      .then((result) => {
        options.onResult?.(submission, result);
        return result;
      });
    // The next batch is built only after this one's result has been handed
    // over, so it sees the canonical model that result produced. The queue
    // moves on whatever a batch came to; the caller sees the failure.
    tails.set(initiativeId, run.catch(() => undefined));

    return run;
  }

  return {
    submit(initiativeId, write) {
      return queue(initiativeId, (context) => intentToBatch(write, context), write);
    },
    submitHistory(initiativeId, action) {
      return queue(initiativeId, () => historyBatch(initiativeId, action), null);
    },
  };
}
