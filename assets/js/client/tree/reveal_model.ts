// Revealing the task a link names (m04.02 item 2.2.3).
//
// A link from Assigned to Me, from the bell, or pasted into a chat carries
// `?task=<id>`. Landing on the Initiative is not enough: if the task sits inside
// a branch the user collapsed, it is not on the glass, and a highlight nobody
// can see is the same as no answer at all. So the client expands every collapsed
// ancestor, selects the task, and scrolls it into view — exactly what the
// LiveView's `deep-link-task` handler does (`initiative_workspace_live.ex:3186`),
// which `honor_task_param/2` exists to trigger.
//
// The parameter also has to survive being read. Everything here is a decision
// about strings and ids, so it is decided in one tested place and the hook is
// left with nothing but the DOM call.

import type { TreeModel } from "./model.ts";
import { branchesToOpen } from "./tree_model.ts";

/** The query parameter the deep link travels in. The LiveView's name for it. */
export const TASK_PARAM = "task";

/**
 * The task id in a query string, or nothing. Anything that is not a positive
 * whole number is nothing: a link with `?task=` or `?task=nope` opens the
 * Initiative, it does not throw and it does not select row zero.
 */
export function taskParam(search: string): number | null {
  const raw = new URLSearchParams(search).get(TASK_PARAM);
  if (raw === null || raw.trim() === "") return null;
  const id = Number(raw);
  return Number.isInteger(id) && id > 0 ? id : null;
}

export interface RevealPlan {
  /** Collapsed ancestors, outermost first — the order they must be opened in. */
  readonly expand: readonly number[];
  /** The task to select and scroll to, or nothing if this tree has no such task. */
  readonly select: number | null;
}

/** What it takes to put `id` on the glass. */
export function revealPlan(
  model: TreeModel,
  id: number,
  collapsed: (id: number) => boolean,
): RevealPlan {
  if (model.tasks[id] === undefined) return { expand: [], select: null };
  return { expand: branchesToOpen(model, id, collapsed), select: id };
}

/**
 * `search` with the task parameter set to `id`, or removed when there is no
 * selection. Every other parameter is left exactly where it was: the address bar
 * is not ours to rewrite, only the one parameter we own.
 */
export function searchWithTask(search: string, id: number | null): string {
  const params = new URLSearchParams(search);
  if (id === null) params.delete(TASK_PARAM);
  else params.set(TASK_PARAM, String(id));
  const next = params.toString();
  return next === "" ? "" : `?${next}`;
}

/**
 * The task an Initiative screen opens with, decided before anything renders.
 *
 * Selection is per Initiative. `ui.selectedTaskId` is one flat field that
 * outlives the screen, so the task the user selected in the Initiative they came
 * from is still sitting in it when this one mounts. Inheriting it would clear the
 * row a `?task=` link just revealed — the link wins, a selection this tree
 * actually contains is kept, and anything else is dropped.
 */
export function initialSelection(
  model: TreeModel,
  deepLinkTaskId: number | null,
  storedSelectedId: number | null,
): number | null {
  if (deepLinkTaskId !== null && model.tasks[deepLinkTaskId] !== undefined) return deepLinkTaskId;
  if (storedSelectedId !== null && model.tasks[storedSelectedId] !== undefined) {
    return storedSelectedId;
  }
  return null;
}

/**
 * The search string the screen should write on arrival, or `null` for "leave the
 * address bar alone". A link that already names the task we resolved needs no
 * write at all — which is the point: a strip now and a restore a commit later is
 * two entries' worth of churn for no change, and if anything goes wrong in
 * between the parameter is gone for good.
 */
export function firstUrlWrite(search: string, resolved: number | null): string | null {
  const next = searchWithTask(search, resolved);
  return next === search || (search === "" && next === "") ? null : next;
}
