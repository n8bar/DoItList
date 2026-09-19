// Predictions over canonical truth (m04.02 items 5.2.2, 5.2.3).
//
// The tree the user sees is the canonical model with every unanswered write's
// prediction folded on top, in submission order. That fold is the whole
// reconciliation rule:
//
//   * a write begins → its prediction is appended, and the screen shows the
//     fold — the user is acknowledged in the same frame (UX_GUARDRAILS §6);
//   * a write succeeds → its reply delta goes into the canonical model, its
//     prediction is dropped, and the still-pending predictions are re-run on
//     the new canonical (a rebase), so the screen never shows a stale guess
//     over fresh truth and never loses a later guess to an earlier reply;
//   * a write is rejected → its prediction is dropped and the rest are re-run,
//     which is exactly the revert: canonical state plus what is still pending.
//
// Predictions are display-only. Nothing here is ever sent, and a reply lands on
// the canonical model alone — a prediction can never become truth by staying
// on screen long enough.

import type { TreeDelta } from "./delta.ts";
import { applyDelta } from "./delta.ts";
import type { TreeModel } from "./model.ts";

export interface Flight {
  /** The submission's idempotency key. */
  readonly key: string;
  /** The write's prediction, re-runnable against whatever base it is rebased onto. */
  readonly predict: (base: TreeModel) => TreeModel;
  /** The stand-in id an add's prediction gave the new row; `null` otherwise. */
  readonly tempId: number | null;
}

export interface OptimisticState {
  readonly canonical: TreeModel;
  readonly flights: readonly Flight[];
}

export function idle(canonical: TreeModel): OptimisticState {
  return { canonical, flights: [] };
}

/** The canonical model with every in-flight prediction folded on, in order. */
export function shown(state: OptimisticState): TreeModel {
  return state.flights.reduce((model, flight) => flight.predict(model), state.canonical);
}

export function begin(
  state: OptimisticState,
  flight: Flight,
): { state: OptimisticState; shown: TreeModel } {
  const next = { canonical: state.canonical, flights: [...state.flights, flight] };
  return { state: next, shown: shown(next) };
}

/**
 * Lands one reply. `createdId` is the record the delta brought that canonical
 * did not hold — the server id that replaces an add's stand-in.
 */
export function succeed(
  state: OptimisticState,
  key: string,
  delta: TreeDelta,
): { state: OptimisticState; shown: TreeModel; createdId: number | null } {
  const createdId = createdBy(state.canonical, delta);
  const next = {
    canonical: applyDelta(state.canonical, delta).model,
    flights: state.flights.filter((flight) => flight.key !== key),
  };
  return { state: next, shown: shown(next), createdId };
}

/**
 * The record `delta` brings that `canonical` does not hold — the server id
 * that replaces an add's stand-in. One rule, whether the reply or its own
 * broadcast lands first (m04.03 1.4.1).
 */
export function createdBy(canonical: TreeModel, delta: TreeDelta): number | null {
  return delta.upserts.find((upsert) => canonical.tasks[upsert.id] === undefined)?.id ?? null;
}

/** Drops one prediction. What is shown is canonical plus what is still pending. */
export function reject(
  state: OptimisticState,
  key: string,
): { state: OptimisticState; shown: TreeModel } {
  const next = {
    canonical: state.canonical,
    flights: state.flights.filter((flight) => flight.key !== key),
  };
  return { state: next, shown: shown(next) };
}

/**
 * Keeps a stand-in's row key once the server has named the record, so the row
 * React drew for the prediction is the row it keeps drawing (item 5.2.2).
 */
export function alias(
  rowKeys: ReadonlyMap<number, number>,
  createdId: number | null,
  tempId: number | null,
): ReadonlyMap<number, number> {
  if (createdId === null || tempId === null) return rowKeys;
  const next = new Map(rowKeys);
  next.set(createdId, tempId);
  return next;
}
