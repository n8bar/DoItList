// Delta envelopes to test with (m04.03 item 1.4).
//
// Test-only, but it lives beside the parser it feeds so the two stay in step:
// if `DeltaEnvelope` grows a field, `envelope()` stops compiling, and
// `wire()` is the exact payload shape `DoIt.Delta` sends.

import type { DeltaEnvelope, DeltaRecord } from "./envelope.ts";

/** One task record in the envelope's (the snapshot's) shape, with defaults a fresh task has. */
export function record(
  id: number,
  parentId: number,
  position: number,
  extra: Partial<DeltaRecord> = {},
): DeltaRecord {
  return {
    id,
    title: `Task ${id}`,
    description: null,
    index: "",
    position,
    parent_id: parentId,
    depth: 0,
    progress: 0,
    manual_progress: 0,
    status: "open",
    done: false,
    leaf: true,
    priority: "normal",
    assignee_id: null,
    co_assignee_ids: [],
    comment_count: 0,
    cross_references: [],
    referenced_by: [],
    sort_mode: null,
    sort_reverse: false,
    updated_by: null,
    updated_at: null,
    version: 1,
    ...extra,
  };
}

/** A parsed envelope for Initiative 12 at `seq`, empty unless told otherwise. */
export function envelope(seq: number, parts: Partial<DeltaEnvelope> = {}): DeltaEnvelope {
  return {
    initiativeId: 12,
    seq,
    originKey: null,
    actor: null,
    upserts: [],
    removed: [],
    initiative: null,
    membersChanged: false,
    ...parts,
  };
}

/** The same envelope as the channel carries it — snake_case, as JSON. */
export function wire(parsed: DeltaEnvelope): Record<string, unknown> {
  return {
    initiative_id: parsed.initiativeId,
    seq: parsed.seq,
    origin_key: parsed.originKey,
    actor: parsed.actor,
    upserts: parsed.upserts,
    removed: parsed.removed,
    initiative: parsed.initiative,
    members_changed: parsed.membersChanged,
  };
}
