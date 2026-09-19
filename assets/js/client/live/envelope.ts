// The canonical delta envelope, as the Initiative channel pushes it (m04.03 1.4).
//
// One `delta` per committed change: the Initiative's sequence, the idempotency
// key of the batch that caused it (`null` for a server-side pass such as the
// roll-up), who did it, the changed records in the snapshot's own node shape,
// the ids that left, a header patch when the header moved, and whether the
// member list changed. `DoIt.Delta` builds it; this file is the client's word
// on what it accepts.
//
// The check is strict on purpose: a malformed envelope is dropped whole rather
// than half-applied. A dropped envelope leaves a gap in the sequence, and the
// gap rule (`session.ts`) heals that with a fresh snapshot — so refusing is
// always safe, and never silent for long.

import type { ProgressCalc, TaskNode } from "../api/types.ts";
import type { TreeDelta } from "../tree/delta.ts";

/** A task exactly as the snapshot sends it, minus the nested children. */
export type DeltaRecord = Omit<TaskNode, "children">;

export interface DeltaActor {
  readonly id: number;
  readonly name: string;
  readonly username: string;
}

/** The header fields an open view renders, sent whole whenever any of them moved. */
export interface InitiativePatch {
  readonly version: number;
  readonly name: string;
  readonly subtitle: string | null;
  readonly progress: number;
  readonly unit_count: number;
  readonly progress_calc: ProgressCalc;
  readonly index_style: string;
}

export interface DeltaEnvelope {
  readonly initiativeId: number;
  readonly seq: number;
  /** The `Idempotency-Key` of the batch behind this change; `null` when no client write started it. */
  readonly originKey: string | null;
  readonly actor: DeltaActor | null;
  readonly upserts: readonly DeltaRecord[];
  readonly removed: readonly number[];
  readonly initiative: InitiativePatch | null;
  readonly membersChanged: boolean;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isSeq = (value: unknown): value is number =>
  typeof value === "number" && Number.isInteger(value) && value > 0;

const isIdList = (value: unknown): value is number[] =>
  Array.isArray(value) && value.every((id) => typeof id === "number");

/**
 * A `delta` payload from `initiativeId`'s channel, or `null` when it is not
 * one we can apply. Every field the model reads is checked; the rest is
 * carried as the server sent it, exactly as a snapshot's nodes are.
 */
export function parseDelta(initiativeId: number, payload: unknown): DeltaEnvelope | null {
  if (!isRecord(payload)) return null;
  const { initiative_id, seq, origin_key, actor, upserts, removed, initiative, members_changed } =
    payload;
  if (initiative_id !== initiativeId || !isSeq(seq)) return null;
  if (origin_key !== null && origin_key !== undefined && typeof origin_key !== "string") return null;
  if (!Array.isArray(upserts) || !isIdList(removed)) return null;
  if (typeof members_changed !== "boolean") return null;

  const records: DeltaRecord[] = [];
  for (const upsert of upserts) {
    const record = parseRecord(upsert);
    if (record === null) return null;
    records.push(record);
  }

  const patch = initiative === null || initiative === undefined ? null : parsePatch(initiative);
  if (patch === undefined) return null;

  return {
    initiativeId,
    seq,
    originKey: typeof origin_key === "string" ? origin_key : null,
    actor: parseActor(actor),
    upserts: records,
    removed,
    initiative: patch,
    membersChanged: members_changed,
  };
}

function parseRecord(value: unknown): DeltaRecord | null {
  if (!isRecord(value)) return null;
  const { id, parent_id, position, title, version } = value;
  if (typeof id !== "number" || typeof parent_id !== "number") return null;
  if (typeof position !== "number" || typeof title !== "string" || typeof version !== "number") {
    return null;
  }
  const record = value as unknown as DeltaRecord;
  // The same fill-ins `fromSnapshot` makes for a read that predates a field.
  return {
    ...record,
    sort_mode: record.sort_mode ?? null,
    sort_reverse: record.sort_reverse ?? false,
    updated_by: record.updated_by ?? null,
    updated_at: record.updated_at ?? null,
  };
}

/** `undefined` for a patch that is not one — distinct from "no patch". */
function parsePatch(value: unknown): InitiativePatch | undefined {
  if (!isRecord(value)) return undefined;
  const { version, name, subtitle, progress, unit_count, progress_calc, index_style } = value;
  if (typeof version !== "number" || typeof name !== "string") return undefined;
  if (typeof progress !== "number" || typeof unit_count !== "number") return undefined;
  if (typeof progress_calc !== "string" || typeof index_style !== "string") return undefined;
  return {
    version,
    name,
    subtitle: typeof subtitle === "string" ? subtitle : null,
    progress,
    unit_count,
    progress_calc: progress_calc as ProgressCalc,
    index_style,
  };
}

function parseActor(value: unknown): DeltaActor | null {
  if (!isRecord(value)) return null;
  const { id, name, username } = value;
  if (typeof id !== "number" || typeof name !== "string" || typeof username !== "string") return null;
  return { id, name, username };
}

/**
 * The envelope as the one delta shape the model accepts (`applyDelta`). The
 * header patch's `progress_calc` and `index_style` are not header fields on
 * the model; `session.ts` applies those two itself.
 */
export function deltaFrom(envelope: DeltaEnvelope): TreeDelta {
  const delta: TreeDelta = { upserts: [...envelope.upserts], removed: [...envelope.removed] };
  const patch = envelope.initiative;
  if (patch !== null) {
    delta.initiative = {
      name: patch.name,
      subtitle: patch.subtitle,
      progress: patch.progress,
      unit_count: patch.unit_count,
      version: patch.version,
    };
  }
  return delta;
}
