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
//
// Every batch is journaled on the device before it can be lost (m04.03 2.1):
// the intent as it is queued, then the exact body under the exact key before
// the POST goes out, and the record is deleted only once the server's answer
// is known. A transport failure is not an answer: the batch stays journaled
// as `sent`, its prediction stays on screen, and the queue behind it waits —
// the send parks until the screen says the connection is back (`resume`), and
// then the same body goes out under the same key. A record another life of
// this tab left behind comes back through `resubmit` (m04.03 2.3).
//
// Replay is a rebase (m04.03 3.2): a batch that has never been on the wire is
// built from its intent against canonical as it stands now — after the server's
// snapshot, not before it. Bytes that HAVE been on the wire with the outcome
// unknown go again exactly as they were, under the same key, because the
// server may already hold their result; if the answer is a version conflict,
// the world moved while the link was down, and the intent is rebuilt once
// against current truth and sent once more under a NEW key (the old one names
// bytes the server refused). A second conflict is a rejection. An intent whose
// target is gone is refused here, visibly, rather than sent as nothing.
//
// Edits are the exception to "once" (m04.03 4.4): a stale edit is rebased
// field by field onto the record the conflict reply carries — the user's
// fields only, with the version the server is at — and sent again under a new
// key, up to `MAX_EDIT_ATTEMPTS` sends counted in the journal; past that, or
// on any other refusal, the edit is kept in the journal as `rejected` with its
// reason, for the pane's Retry and Discard (4.6.2), instead of being removed.
// A move is re-read against the tree as it stands before it goes (4.5), and a
// write the user's current role forbids is refused without a request (4.7).
// `abandon` drops an Initiative's lane when access to it is lost: nothing more
// goes out for it, and a reply still on its way is ignored.

import type { ApiClient, ApiError } from "../api/client.ts";
import type { Priority } from "../api/types.ts";
import type { PendingOpRecord } from "../storage/db.ts";
import type { BatchBody, PendingIntent, PendingOp } from "../storage/pending_ops.ts";
import type { AddRequest } from "./add_form_model.ts";
import type { TreeIntent } from "./context.ts";
import type { HistoryResult, TaskResult, TaskUpsert, TreeDelta } from "./delta.ts";
import { deltaFromHistoryResult, deltaFromOpResult } from "./delta.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { clientRefusal } from "./notice_model.ts";
import type { OpResult } from "./ops.ts";
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
import { permissionsFor, permitsWrite } from "./permissions.ts";
import type { MoveWrite } from "./rebase.ts";
import {
  EDIT_CONTENDED,
  MAX_EDIT_ATTEMPTS,
  NO_PERMISSION,
  TARGET_GONE,
  currentFromConflict,
  moveArgsFor,
  rebaseEdit,
  reevaluateMove,
} from "./rebase.ts";

export { TARGET_GONE, moveArgsFor } from "./rebase.ts";

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

/**
 * Whether the write still has somewhere to land: its row, and for an add or a
 * move the parent it names. A write whose target is gone can never apply, which
 * is different from one that now changes nothing (m04.03 3.2.1).
 */
export function targetExists(write: TreeWrite, model: TreeModel): boolean {
  const holds = (id: number) => id === model.rootId || model.tasks[id] !== undefined;
  if (write.kind === "add") return holds(write.request.parentId);
  if (model.tasks[write.id] === undefined) return false;
  return write.kind === "move" ? holds(write.parentId) : true;
}

/** The refusal for a batch whose Initiative the user lost while it was queued or out (m04.03 4.7). */
export const ACCESS_LOST: ApiError = clientRefusal("forbidden", "You no longer have access to this Initiative.");

const isMove = (write: TreeWrite): write is MoveWrite =>
  write.kind === "reorder" || write.kind === "indent" || write.kind === "outdent" || write.kind === "move";

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
  /** The delivery sequence each Initiative the batch touched advanced to (m04.03 1.2). */
  seq?: Record<string, number>;
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
  | {
      ok: true;
      delta: TreeDelta;
      refetch: boolean;
      affectedIds: number[];
      /** The Initiative's sequence this reply is at, when the server said (m04.03 1.4.1). */
      seq?: number;
    }
  | {
      ok: false;
      error: ApiError;
      affectedIds: number[];
      /**
       * The journal kept the write as `rejected` under the submission's key,
       * with its reason: an edit the pane can offer Retry and Discard for
       * (m04.03 4.6.2). `false` means the record is gone with the refusal.
       */
      recoverable: boolean;
      /** The Initiative's lane was dropped (`abandon`): no one is told, nothing is journaled. */
      abandoned?: true;
    };

/** What a submission looks like the moment it is queued — item 5.2's pending scope. */
export interface Submission {
  key: string;
  initiativeId: number;
  affectedIds: number[];
  /** The write this batch carries; `null` for undo/redo. */
  write: TreeWrite | null;
}

/** Where queued operations are kept while their outcome is unknown (m04.03 2.1). */
export interface OperationJournal {
  /** Writes or rewrites the record under its key. A refusal is not the adapter's problem. */
  put(record: PendingOpRecord): Promise<unknown>;
  /** The outcome is known. */
  remove(key: string): Promise<unknown>;
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
  /** The device's journal. Without one, nothing survives the tab. */
  journal?: OperationJournal;
  /** Injected in tests; defaults to `Date.now()`. */
  now?: () => number;
  /** Fires synchronously as a batch is queued, before anything is sent. */
  onSubmit?: (submission: Submission) => void;
  /** Fires with the outcome of each batch, in order per Initiative. */
  onResult?: (submission: Submission, result: SubmitResult) => void;
  /**
   * Fires when a batch could not reach the server and its outcome is unknown.
   * The batch is parked, not failed: nothing on screen is to change.
   */
  onUnknown?: (submission: Submission, error: ApiError) => void;
}

export interface OperationAdapter {
  submit(initiativeId: number, write: TreeWrite): Promise<SubmitResult>;
  submitHistory(initiativeId: number, action: "undo" | "redo"): Promise<SubmitResult>;
  /**
   * A record the device kept (m04.03 2.3): sent again under its own key. One
   * that went out once resends its stored body as it was; one that never went
   * builds its body from its intent, against truth as it stands. Replays ride
   * ahead of anything queued before `open`, so what an earlier life of the
   * tab asked for goes first. `onSubmit` does not fire — the caller has
   * already put the record's prediction on screen.
   */
  resubmit(record: PendingOp): Promise<SubmitResult>;
  /**
   * Holds the ordinary queue for `initiativeId` until `open`: called before
   * anything can be queued, so the boot replay goes first (m04.03 2.3.1).
   */
  hold(initiativeId: number): void;
  /** The boot replay for `initiativeId` is queued: everything else may go. */
  open(initiativeId: number): void;
  /** The connection is back: a batch parked on an unknown outcome goes again. */
  resume(initiativeId: number): void;
  /**
   * Access to `initiativeId` is gone (m04.03 4.7): its lane is dropped. A
   * batch waiting its turn never goes; one parked on an unknown outcome is
   * not resent; a reply still on its way lands nowhere — `onResult` is not
   * called and the journal is not touched (the cache has already purged it).
   */
  abandon(initiativeId: number): void;
}

interface Job {
  readonly submission: Submission;
  readonly createdAt: number;
  readonly intent: PendingIntent;
  /** A body already sent once, resent as it was; `null` builds one at send time. */
  readonly body: BatchBody | null;
  /** Distinct bodies of this submission that have been on the wire so far (4.4). */
  readonly attempts: number;
  /** The lane's generation when it was queued: a bump since means `abandon` dropped it. */
  readonly generation: number;
  /** The queued record's write, awaited before the send. Never rejects. */
  readonly journaled: Promise<unknown>;
}

/** What an intent comes to against truth now. */
type Built =
  /** It cannot apply now — the target is gone, the move is impossible, the role forbids it — and the user is told. */
  | { kind: "refused"; error: ApiError }
  /** It would change nothing now (already so): nothing to send. */
  | { kind: "nothing" }
  | { kind: "batch"; body: BatchBody };

const intentOf = (write: TreeWrite | null, action: "undo" | "redo"): PendingIntent =>
  write === null ? { kind: "history", action } : { kind: "write", write };

/** The batch an intent makes now, against `context`. */
function buildIntent(intent: PendingIntent, initiativeId: number, context: BatchContext): Batch {
  return intent.kind === "history"
    ? historyBatch(initiativeId, intent.action)
    : intentToBatch(intent.write, context);
}

export function createAdapter(options: AdapterOptions): OperationAdapter {
  const keyGen = options.keyGen ?? (() => crypto.randomUUID());
  const now = options.now ?? (() => Date.now());
  const sendContext = options.sendContext ?? options.context;
  // A journal that cannot fail the send: a refused write is the storage
  // line's business, and the batch goes anyway (the memory store stands in).
  // The call itself is made in the caller's step (a queued record is handed to
  // the device in the same tick as the prediction goes on screen); only the
  // outcome is awaited.
  const attempt = (work: (() => Promise<unknown>) | undefined): Promise<unknown> => {
    if (work === undefined) return Promise.resolve();
    try {
      return work().catch(() => undefined);
    } catch {
      return Promise.resolve();
    }
  };
  const device = options.journal;
  const journal = {
    put: (record: PendingOpRecord): Promise<unknown> =>
      attempt(device === undefined ? undefined : () => device.put(record)),
    remove: (key: string): Promise<unknown> =>
      attempt(device === undefined ? undefined : () => device.remove(key)),
  };

  // The tail of each Initiative's queue. A batch is chained onto it at submit
  // time, so creation order is send order and only one is ever in flight.
  const tails = new Map<number, Promise<unknown>>();
  // The replay lane: what an earlier life of the tab queued goes first. A
  // gate, while one is held, keeps the ordinary lane waiting until `open`
  // says the replays are all queued. No gate means nothing to wait for.
  const replays = new Map<number, Promise<unknown>>();
  const gates = new Map<number, { promise: Promise<unknown>; open: (after: Promise<unknown>) => void; opened: boolean }>();
  // One parked send per Initiative: the one whose outcome is unknown.
  const parked = new Map<number, () => void>();
  // Every batch this adapter has queued and not yet answered, by key. A replay
  // of one of them is that batch, not a second copy of it.
  const active = new Map<string, Promise<SubmitResult>>();
  // Bumped by `abandon`: a job compares the value it was queued under with the
  // value now, and one that differs is a job for an Initiative the user lost.
  const generations = new Map<number, number>();
  const generation = (initiativeId: number): number => generations.get(initiativeId) ?? 0;

  const emptyOk = (affectedIds: number[]): SubmitResult => ({
    ok: true,
    delta: { upserts: [], removed: [] },
    refetch: false,
    affectedIds,
  });

  const recordOf = (
    job: Job,
    key: string,
    body: BatchBody | null,
    status: "queued" | "sent",
    attempts: number,
  ): PendingOpRecord => ({
    key,
    initiativeId: job.submission.initiativeId,
    createdAt: job.createdAt,
    payload: { ...job.intent, body, status, attempts },
  });

  const writeOf = (job: Job): TreeWrite | null => (job.intent.kind === "write" ? job.intent.write : null);

  /**
   * The intent against canonical as it stands now — the rebase. A target that
   * is gone, a role that forbids the write (4.7) and a move that can no longer
   * be made (4.5) are refused here, before anything is sent.
   */
  const build = (job: Job): Built => {
    const { initiativeId } = job.submission;
    const context = sendContext(initiativeId);
    if (context === undefined) return { kind: "nothing" };
    const write = writeOf(job);
    if (write !== null && !targetExists(write, context.model)) return { kind: "refused", error: TARGET_GONE };
    const permissions = permissionsFor(context.model.header.role);
    if (!permitsWrite(permissions, write)) return { kind: "refused", error: NO_PERMISSION };
    if (write !== null && isMove(write)) {
      const verdict = reevaluateMove(write, context.model, permissions);
      if (verdict.kind !== "move") return verdict;
    }
    const { operations } = buildIntent(job.intent, initiativeId, context);
    return operations.length === 0 ? { kind: "nothing" } : { kind: "batch", body: { operations } };
  };

  async function send(job: Job): Promise<SubmitResult> {
    const { submission } = job;
    const { initiativeId, affectedIds } = submission;
    const abandoned = (): boolean => generation(initiativeId) !== job.generation;
    const dropped: SubmitResult = { ok: false, error: ACCESS_LOST, affectedIds, recoverable: false, abandoned: true };

    await job.journaled;
    if (abandoned()) return dropped;

    // The key the bytes go out under. The submission's key, until a conflict
    // makes the rebuilt batch a new request.
    let key = submission.key;
    let body = job.body;
    // Whether `body` has been on the wire before with its outcome unknown. A
    // conflict on such bytes is the world having moved meanwhile, and buys
    // one rebuild; a conflict on bytes built just now is a rejection — except
    // for an edit, which is rebased field by field within its bound (4.4).
    let resent = body !== null;
    let rebuilt = false;
    let attempts = job.attempts;

    /**
     * A refusal that will not change on its own. An edit whose row is still
     * here is kept in the journal as `rejected`, under the key the screen
     * knows it by, for Retry and Discard (4.6.2); anything else is forgotten.
     */
    const refuse = async (error: ApiError): Promise<SubmitResult> => {
      const write = writeOf(job);
      const model = sendContext(initiativeId)?.model;
      const keep = write?.kind === "edit" && model?.tasks[write.id] !== undefined && !abandoned();
      if (!keep) {
        void journal.remove(key);
        return { ok: false, error, affectedIds, recoverable: false };
      }
      await journal.put({
        key: submission.key,
        initiativeId,
        createdAt: job.createdAt,
        payload: { ...job.intent, body: null, status: "rejected", reason: rejectionMessage(error), attempts },
      });
      if (key !== submission.key) await journal.remove(key);
      return { ok: false, error, affectedIds, recoverable: true };
    };

    if (body === null) {
      // Built now, from truth as the previous reply (or the snapshot) left it.
      const built = build(job);
      if (built.kind === "nothing") {
        await journal.remove(key);
        return emptyOk(affectedIds);
      }
      if (built.kind === "refused") return refuse(built.error);
      body = built.body;
      attempts += 1;
    }

    // The exact body under the exact key, on the device before it goes out:
    // a tab that dies mid-request comes back and sends this again.
    if (abandoned()) return dropped;
    await journal.put(recordOf(job, key, body, "sent", attempts));

    for (;;) {
      const headers = { "idempotency-key": key };
      let result = await options.api.post<BatchReply>("/operations", body, headers);
      // A reply that never arrived: the same key replays a commit the server
      // did make, and re-runs one it did not. Once — a link that is down
      // stays down.
      if (!result.ok && result.error.code === "network" && !abandoned()) {
        result = await options.api.post<BatchReply>("/operations", body, headers);
      }
      // Access went while the request was out: whatever came back is not ours to apply.
      if (abandoned()) return dropped;
      if (!result.ok && result.error.code === "network") {
        // Unknown outcome. The record stays, the prediction stays, the queue
        // behind this waits, and the same body goes again when told to.
        options.onUnknown?.(submission, result.error);
        await new Promise<void>((resolve) => parked.set(initiativeId, resolve));
        if (abandoned()) return dropped;
        resent = true;
        continue;
      }

      const write = writeOf(job);
      if (!result.ok && result.error.code === "conflict" && write?.kind === "edit") {
        // Stale (4.4): the user's fields onto the record as the server has it
        // now — from the reply, else from canonical — under a new key. Only
        // so many times: past the bound the edit is the user's to retry.
        if (attempts >= MAX_EDIT_ATTEMPTS) return refuse(EDIT_CONTENDED);
        const current = currentFromConflict(result.error) ?? sendContext(initiativeId)?.model.tasks[write.id];
        if (current === undefined) return refuse(TARGET_GONE);
        const operation = rebaseEdit(write, current);
        if (operation === null) {
          // Already so — someone else got there with the same value.
          void journal.remove(key);
          return emptyOk(affectedIds);
        }
        const stale = key;
        key = keyGen();
        body = { operations: [operation] };
        attempts += 1;
        resent = false;
        // The new key is on the device before the old one goes, so a tab that
        // dies between the two never loses the intent — and never resends
        // the refused bytes. The count goes with it.
        await journal.put(recordOf(job, key, body, "sent", attempts));
        await journal.remove(stale);
        continue;
      }

      if (!result.ok && result.error.code === "conflict" && resent && !rebuilt) {
        // The bytes were stale, not the intent. Once more, from truth now.
        rebuilt = true;
        const built = build(job);
        if (built.kind === "nothing") {
          void journal.remove(key);
          return emptyOk(affectedIds);
        }
        if (built.kind === "refused") return refuse(built.error);
        const stale = key;
        key = keyGen();
        body = built.body;
        attempts += 1;
        resent = false;
        await journal.put(recordOf(job, key, body, "sent", attempts));
        await journal.remove(stale);
        continue;
      }

      if (!result.ok) return refuse(result.error);
      void journal.remove(key);
      const { refetch, ...delta } = deltaFromReply(body.operations, result.data);
      const seq = result.data.seq?.[String(initiativeId)];
      return {
        ok: true,
        delta,
        refetch,
        affectedIds,
        ...(typeof seq === "number" ? { seq } : {}),
      };
    }
  }

  /** Chains `job` after `previous`, hands its outcome over, and answers with it. */
  function run(job: Job, previous: Promise<unknown>): Promise<SubmitResult> {
    const { key } = job.submission;
    const running = previous
      .then(() => send(job))
      .then((result) => {
        active.delete(key);
        // A dropped lane's outcome is nobody's: the screen has already forgotten the tree.
        if (result.ok || result.abandoned !== true) options.onResult?.(job.submission, result);
        return result;
      });
    active.set(key, running);
    return running;
  }

  function queue(initiativeId: number, write: TreeWrite | null, action: "undo" | "redo"): Promise<SubmitResult> {
    const intent = intentOf(write, action);
    // Against what is shown, for whether anything would go and what it touches.
    const context = options.context(initiativeId);
    const preview = context === undefined ? EMPTY : buildIntent(intent, initiativeId, context);
    if (preview.operations.length === 0) return Promise.resolve(emptyOk([]));

    const submission: Submission = {
      key: keyGen(),
      initiativeId,
      affectedIds: preview.affectedIds,
      write,
    };
    options.onSubmit?.(submission);

    // On the device in the same step as it is on screen — before anything
    // is sent, and before memory can forget it.
    const createdAt = now();
    const journaled = journal.put({
      key: submission.key,
      initiativeId,
      createdAt,
      payload: { ...intent, body: null, status: "queued", attempts: 0 },
    });
    const job: Job = { submission, createdAt, intent, body: null, attempts: 0, generation: generation(initiativeId), journaled };

    const previous = tails.get(initiativeId) ?? gates.get(initiativeId)?.promise ?? Promise.resolve();
    const running = run(job, previous);
    // The next batch is built only after this one's result has been handed
    // over, so it sees the canonical model that result produced. The queue
    // moves on whatever a batch came to; the caller sees the failure.
    tails.set(initiativeId, running.catch(() => undefined));
    return running;
  }

  return {
    submit: (initiativeId, write) => queue(initiativeId, write, "undo"),
    submitHistory: (initiativeId, action) => queue(initiativeId, null, action),

    resubmit(record) {
      const { key, initiativeId, createdAt, payload } = record;
      const already = active.get(key);
      if (already !== undefined) return already;
      const write = payload.kind === "write" ? payload.write : null;
      const context = options.context(initiativeId);
      const preview = context === undefined ? EMPTY : buildIntent(payload, initiativeId, context);
      const submission: Submission = { key, initiativeId, affectedIds: preview.affectedIds, write };
      // A `rejected` record is not replayed (`replayPlan` leaves it out); one
      // handed here anyway is built afresh, as a Retry would.
      const sent = payload.status === "sent";
      const job: Job = {
        submission,
        createdAt,
        intent: payload.kind === "write" ? { kind: "write", write: payload.write } : { kind: "history", action: payload.action },
        body: sent ? payload.body : null,
        // A record from before the count was kept has been out once if it was sent.
        attempts: payload.attempts ?? (sent ? 1 : 0),
        generation: generation(initiativeId),
        journaled: Promise.resolve(),
      };
      // While the gate is held, replays go ahead of the ordinary lane; once it
      // is open there is ONE lane, and a later replay (a resync's, m04.03 3.3)
      // takes its turn in it — never a second batch in flight.
      const gate = gates.get(initiativeId);
      const ahead = gate !== undefined && !gate.opened;
      const previous = ahead
        ? (replays.get(initiativeId) ?? Promise.resolve())
        : (tails.get(initiativeId) ?? replays.get(initiativeId) ?? Promise.resolve());
      const running = run(job, previous);
      (ahead ? replays : tails).set(initiativeId, running.catch(() => undefined));
      return running;
    },

    hold(initiativeId) {
      if (gates.has(initiativeId)) return;
      let open: (after: Promise<unknown>) => void = () => {};
      const promise = new Promise<unknown>((resolve) => {
        open = resolve;
      });
      gates.set(initiativeId, { promise, open, opened: false });
    },

    open(initiativeId) {
      const gate = gates.get(initiativeId);
      if (gate === undefined || gate.opened) return;
      gate.opened = true;
      gate.open(replays.get(initiativeId) ?? Promise.resolve());
    },

    resume(initiativeId) {
      const go = parked.get(initiativeId);
      if (go === undefined) return;
      parked.delete(initiativeId);
      go();
    },

    abandon(initiativeId) {
      generations.set(initiativeId, generation(initiativeId) + 1);
      // The lane goes whole: what is chained on it finds itself abandoned and
      // steps aside without sending; what comes after access is granted again
      // starts a fresh chain.
      tails.delete(initiativeId);
      replays.delete(initiativeId);
      gates.delete(initiativeId);
      // A parked send is woken so it can see it is abandoned, not to go again.
      const go = parked.get(initiativeId);
      parked.delete(initiativeId);
      go?.();
    },
  };
}
