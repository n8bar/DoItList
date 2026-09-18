// What the tree tells a screen reader (m04.02 item 7.12.2): one short line per
// selection or collapse change, for the tree's polite live region. Decided
// from the model, so the words are the same whichever control made the change.

import type { TreeModel } from "./model.ts";
import { ancestors, childIdsOf } from "./model.ts";

export const NOTHING_SELECTED = "Nothing selected";

/** "Selected Bravo, level 2, 1 of 3" — or the empty selection, said plainly. */
export function selectionAnnouncement(model: TreeModel, id: number | null): string | null {
  if (id === null) return NOTHING_SELECTED;
  const record = model.tasks[id];
  if (record === undefined) return null;
  const level = ancestors(model, id).filter((above) => above !== model.rootId).length + 1;
  const siblings = childIdsOf(model, record.parent_id);
  return `Selected ${record.title}, level ${level}, ${siblings.indexOf(id) + 1} of ${siblings.length}`;
}

/** "Bravo collapsed", "Bravo expanded" — for every branch whose state changed. */
export function collapseAnnouncement(
  model: TreeModel,
  before: ReadonlySet<number>,
  after: ReadonlySet<number>,
): string | null {
  const parts: string[] = [];
  for (const id of after) {
    if (!before.has(id) && model.tasks[id] !== undefined) parts.push(`${model.tasks[id].title} collapsed`);
  }
  for (const id of before) {
    if (!after.has(id) && model.tasks[id] !== undefined) parts.push(`${model.tasks[id].title} expanded`);
  }
  return parts.length === 0 ? null : parts.join(", ");
}

export interface AnnouncedState {
  readonly selectedId: number | null;
  readonly collapsedIds: ReadonlySet<number>;
}

/**
 * The one line for a change between two states, or `null` when nothing a
 * screen reader should hear happened. A selection change wins over a collapse
 * change in the same commit: a reveal opens branches on its way to the row.
 */
export function announcementFor(
  model: TreeModel,
  before: AnnouncedState,
  after: AnnouncedState,
): string | null {
  if (before.selectedId !== after.selectedId) return selectionAnnouncement(model, after.selectedId);
  return collapseAnnouncement(model, before.collapsedIds, after.collapsedIds);
}
