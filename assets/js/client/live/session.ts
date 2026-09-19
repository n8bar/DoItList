// One Initiative's sync session: canonical truth, the sequence it is current
// to, the writes still in flight, and the deltas waiting their turn (m04.03
// item 1.4). Pure — every rule here is a function of the state and one event,
// and `refresh.ts` is the only thing that holds the state and does the reading.
//
// The sequence rules (spec §4):
//
//   * the next envelope (`seq + 1`) is applied once, and anything it unblocks
//     in the buffer follows it (1.4.3);
//   * an older or repeated envelope is dropped (1.4.2);
//   * a later one is held, because the one before it may still be on its way;
//     if the gap stays open the caller re-reads the tree and installs it, and
//     the held envelopes newer than that read follow (1.4.4);
//   * a client's own write meets its own broadcast in either order, and
//     exactly one of them settles the prediction (1.4.1). Whichever lands
//     first drops the flight; the broadcast's full records always reach
//     canonical, so the tree ends the same both ways.
//
// A snapshot installs only forward: a read older than what the session
// already knows is refused, never drawn over newer truth. Subscribing comes
// before the read (spec §4, m04.03 3.1): envelopes that arrive while the read
// is out are held here, and `install` applies the ones newer than the read
// and drops the rest — the snapshot/broadcast race closes without an event log.
//
// The canonical model is never what is shown. `shown` folds the unanswered
// predictions on top (`optimistic.ts`), so a delta landing under a pending
// write cannot erase the write's guess — the guess is re-run over the new
// truth, the same as it is over a reply.

import type { InitiativeTree } from "../api/types.ts";
import type { TreeDelta } from "../tree/delta.ts";
import { applyDelta, deltaFromSnapshot } from "../tree/delta.ts";
import { relabel } from "../tree/labels.ts";
import type { InitiativeHeader, TreeModel } from "../tree/model.ts";
import { fromSnapshot, isBranch } from "../tree/model.ts";
import type { Flight } from "../tree/optimistic.ts";
import { createdBy } from "../tree/optimistic.ts";
import { recomputeBranches } from "../tree/progress.ts";
import type { DeltaEnvelope } from "./envelope.ts";
import { deltaFrom } from "./envelope.ts";

/** How long a gap is given to fill itself before the tree is re-read. */
export const GAP_HOLD_MS = 750;

/** How many envelopes are held for a gap. Past this the tree is re-read at once. */
export const BUFFER_LIMIT = 64;

export interface SessionState {
  /** Server truth, or `null` before the first snapshot has landed. */
  readonly canonical: TreeModel | null;
  /** The writes whose reply or broadcast has not settled them, in submission order. */
  readonly flights: readonly Flight[];
  /** Envelopes ahead of the sequence, by their `seq`. */
  readonly buffered: ReadonlyMap<number, DeltaEnvelope>;
  /** Keys whose own broadcast landed first: the reply, when it comes, has nothing left to do. */
  readonly acked: ReadonlySet<string>;
  /**
   * The highest sequence the server is known to have reached — from a held
   * envelope or from a reply's `seq`. Above `seqOf` it means envelopes are
   * missing, whether or not any are held.
   */
  readonly expected: number;
  /**
   * A snapshot from the server has installed. The device's copy alone does not
   * count: pending intent is replayed only over truth the server handed over
   * (m04.03 3.2).
   */
  readonly synced: boolean;
}

export const emptySession: SessionState = {
  canonical: null,
  flights: [],
  buffered: new Map(),
  acked: new Set(),
  expected: 0,
  synced: false,
};

/** A write its own broadcast settled before its reply arrived. */
export interface Settled {
  readonly flight: Flight;
  /** The server id of the row the write added, if it added one. */
  readonly createdId: number | null;
}

/** What one event did, besides the new state. */
export interface Outcome {
  readonly state: SessionState;
  /** Envelopes applied to canonical, in order. */
  readonly applied: readonly DeltaEnvelope[];
  /** Flights settled by their own broadcast, in order. */
  readonly settled: readonly Settled[];
  /** The buffer overflowed: re-read the tree now rather than wait out the hold. */
  readonly overflow: boolean;
}

/** The sequence canonical is current to; 0 before there is a canonical. */
export function seqOf(state: SessionState): number {
  return state.canonical?.seq ?? 0;
}

/** Whether envelopes are known to be missing. Meaningless before a snapshot. */
export function gapOpen(state: SessionState): boolean {
  return state.canonical !== null && state.expected > seqOf(state);
}

/** Canonical with every unanswered prediction folded on, in order. */
export function shown(state: SessionState): TreeModel | null {
  if (state.canonical === null) return null;
  return state.flights.reduce((model, flight) => flight.predict(model), state.canonical);
}

const unchanged = (state: SessionState): Outcome => ({
  state,
  applied: [],
  settled: [],
  overflow: false,
});

/** One envelope off the channel. */
export function receive(state: SessionState, envelope: DeltaEnvelope): Outcome {
  const seq = seqOf(state);
  const expected = Math.max(state.expected, envelope.seq);

  if (state.canonical !== null && envelope.seq <= seq) return unchanged(state);

  if (state.canonical !== null && envelope.seq === seq + 1) {
    return drain(applyOne({ ...state, expected }, envelope));
  }

  // Ahead of us (or before any snapshot): held for the one that comes before
  // it, or for the snapshot that makes it moot.
  const buffered = new Map(state.buffered);
  buffered.set(envelope.seq, envelope);
  const overflow = buffered.size > BUFFER_LIMIT;
  if (overflow) {
    // Keep the newest: the re-read that follows makes the oldest moot first.
    const keep = [...buffered.keys()].sort((a, b) => b - a).slice(0, BUFFER_LIMIT);
    const kept = new Set(keep);
    for (const held of [...buffered.keys()]) if (!kept.has(held)) buffered.delete(held);
  }
  return {
    state: { ...state, buffered, expected },
    applied: [],
    settled: [],
    // Before a snapshot the buffer is only waiting; there is nothing to re-read yet.
    overflow: overflow && state.canonical !== null,
  };
}

/**
 * A snapshot read landed — the first one, a retry, or the re-read a gap asked
 * for. Refused when it is older than what canonical already reached; installed
 * forward otherwise, with every held envelope newer than it applied in order.
 * Throws, as `fromSnapshot` does, when the read cannot be a tree.
 */
export function install(
  state: SessionState,
  tree: InitiativeTree,
): Outcome & { readonly installed: boolean } {
  const previous = state.canonical;
  if (previous !== null && tree.seq < previous.seq) return { ...unchanged(state), installed: false };

  let canonical: TreeModel;
  if (previous === null) {
    canonical = fromSnapshot(tree);
  } else {
    // The style and the calc go on first: `applyDelta` relabels the parents
    // it touches from the model's style, and the read's labels are in the
    // new one.
    const base = { ...previous, indexStyle: tree.index_style, progressCalc: tree.progress_calc };
    canonical = { ...applyDelta(base, deltaFromSnapshot(tree, previous)).model, seq: tree.seq };
  }

  const buffered = new Map<number, DeltaEnvelope>();
  for (const [seq, envelope] of state.buffered) if (seq > tree.seq) buffered.set(seq, envelope);

  const next: SessionState = {
    ...state,
    canonical,
    buffered,
    expected: Math.max(state.expected, tree.seq),
    synced: true,
  };
  return { ...drain(unchanged(next)), installed: true };
}

/**
 * The server said, outside any envelope, that it has reached `seq` — a join
 * reply (m04.03 3.3). Nothing is applied; if it is past canonical the gap is
 * open and the caller reads.
 */
export function heard(state: SessionState, seq: number): SessionState {
  return seq > state.expected ? { ...state, expected: seq } : state;
}

/**
 * The tree this device last saved (m04.03 2.2), to paint before the server
 * answers. It fills an empty session only: once anything from the server is
 * in — a snapshot, or a snapshot plus deltas — a copy from the disk is older
 * by definition and is refused. Held envelopes newer than it follow it, the
 * same as after a read.
 */
export function installCached(
  state: SessionState,
  model: TreeModel,
): Outcome & { readonly installed: boolean } {
  if (state.canonical !== null) return { ...unchanged(state), installed: false };

  const buffered = new Map<number, DeltaEnvelope>();
  for (const [seq, envelope] of state.buffered) if (seq > model.seq) buffered.set(seq, envelope);

  const next: SessionState = {
    ...state,
    canonical: model,
    buffered,
    expected: Math.max(state.expected, model.seq),
  };
  return { ...drain(unchanged(next)), installed: true };
}

/** A write queued: its prediction goes on top until something settles it. */
export function begin(state: SessionState, flight: Flight): SessionState {
  return { ...state, flights: [...state.flights, flight] };
}

/**
 * A write's reply. If its broadcast got here first there is nothing left to
 * apply — the full records are already in. Otherwise the reply's delta lands
 * on canonical and the prediction is dropped; the broadcast, when it comes,
 * is the next consecutive envelope and lands its full records on top, so the
 * tree reads the same whichever came first. A reply whose `seq` is beyond
 * the next one says envelopes are missing (`gapOpen`), without guessing at
 * what they held.
 */
export function acknowledge(
  state: SessionState,
  key: string,
  delta: TreeDelta,
  replySeq?: number,
): { state: SessionState; createdId: number | null; flight: Flight | null } {
  const expected = replySeq === undefined ? state.expected : Math.max(state.expected, replySeq);

  if (state.acked.has(key)) {
    const acked = new Set(state.acked);
    acked.delete(key);
    return { state: { ...state, acked, expected }, createdId: null, flight: null };
  }

  const flight = state.flights.find((candidate) => candidate.key === key) ?? null;
  const flights = state.flights.filter((candidate) => candidate.key !== key);
  if (state.canonical === null) {
    return { state: { ...state, flights, expected }, createdId: null, flight };
  }

  const createdId = createdBy(state.canonical, delta);
  const canonical = applyDelta(state.canonical, delta).model;
  return { state: { ...state, canonical, flights, expected }, createdId, flight };
}

/** A write refused: its prediction goes, and what is shown is truth plus the rest. */
export function reject(state: SessionState, key: string): SessionState {
  return { ...state, flights: state.flights.filter((flight) => flight.key !== key) };
}

/** A header edit's prediction or reply, on canonical so the next rebase keeps it. */
export function patchHeader(
  state: SessionState,
  patch: (header: InitiativeHeader) => InitiativeHeader,
): SessionState {
  if (state.canonical === null) return state;
  const canonical = { ...state.canonical, header: patch(state.canonical.header) };
  return { ...state, canonical };
}

// --- internals --------------------------------------------------------------

/** Applies `envelope` (which must be the next one) and settles the flight it answers. */
function applyOne(state: SessionState, envelope: DeltaEnvelope): Outcome {
  const canonical = state.canonical as TreeModel;
  const flight =
    envelope.originKey === null
      ? undefined
      : state.flights.find((candidate) => candidate.key === envelope.originKey);

  // Before the records go in: what is new is only knowable against the old.
  const createdId = flight === undefined ? null : createdBy(canonical, deltaFrom(envelope));
  const next = applyEnvelope(canonical, envelope);

  if (flight === undefined) {
    return { state: { ...state, canonical: next }, applied: [envelope], settled: [], overflow: false };
  }
  const acked = new Set(state.acked);
  acked.add(flight.key);
  return {
    state: {
      ...state,
      canonical: next,
      flights: state.flights.filter((candidate) => candidate !== flight),
      acked,
    },
    applied: [envelope],
    settled: [{ flight, createdId }],
    overflow: false,
  };
}

/** Applies every held envelope that is now next, in order. */
function drain(outcome: Outcome): Outcome {
  let current = outcome;
  for (;;) {
    const next = current.state.buffered.get(seqOf(current.state) + 1);
    if (next === undefined) return current;
    const buffered = new Map(current.state.buffered);
    buffered.delete(next.seq);
    const step = applyOne({ ...current.state, buffered }, next);
    current = {
      state: step.state,
      applied: [...current.applied, ...step.applied],
      settled: [...current.settled, ...step.settled],
      overflow: current.overflow,
    };
  }
}

/**
 * One envelope onto canonical. The records and the header fields go through
 * `applyDelta`; a changed index style relabels the tree and a changed progress
 * calc recomputes every branch — the header keeps the server's number, and the
 * roll-up pass's own envelope confirms the rows.
 */
function applyEnvelope(canonical: TreeModel, envelope: DeltaEnvelope): TreeModel {
  const patch = envelope.initiative;
  const restyled = patch !== null && patch.index_style !== canonical.indexStyle;
  const recalc = patch !== null && patch.progress_calc !== canonical.progressCalc;

  let base = canonical;
  if (patch !== null && (restyled || recalc)) {
    base = { ...base, indexStyle: patch.index_style, progressCalc: patch.progress_calc };
  }

  let next = applyDelta(base, deltaFrom(envelope)).model;
  if (restyled) next = relabel(next, next.rootId);
  if (recalc) {
    const branches = Object.keys(next.tasks)
      .map(Number)
      .filter((id) => isBranch(next, id));
    next = recomputeBranches(next, branches).model;
  }
  return { ...next, seq: envelope.seq };
}
