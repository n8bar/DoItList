// What the tree shows, and how wide it has to be (m04.02 items 2.2.1, 2.2.2, 2.2.6).
//
// Three rules live here, none of which needs a browser to decide:
//
//  * which rows are visible — the pre-order walk that collapse prunes, and the
//    list every arrow key, every Home/End and the add form's walk step through;
//  * where a branch's open state is kept — the SAME `localStorage` key the
//    LiveView's `CollapseToggle` hook uses, so a tab that has both routes open
//    agrees with itself, and so a branch's open state never depends on its
//    child count (a branch that loses its last child stays open at 0%);
//  * how wide the tree is — deep indentation scrolls sideways rather than
//    squeezing titles (ProductSpec §6.2), and every top-level row is as wide as
//    the widest one so the list reads as a column.

import { ancestors, childIdsOf } from "./model.ts";
import type { TreeModel } from "./model.ts";

/**
 * `phx:collapse:<initiativeId>:<taskId>` — `Hooks.CollapseToggle`'s key, spelled
 * once. "1" is collapsed; anything else, including nothing at all, is open.
 */
export function collapseKey(initiativeId: number, taskId: number): string {
  return `phx:collapse:${initiativeId}:${taskId}`;
}

/** Somewhere to keep a per-branch flag. `localStorage`, or a stand-in in tests. */
export interface CollapseStore {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

/**
 * Reads whether a branch is collapsed. A store that throws — private mode, site
 * data blocked — reads as open: a tree the user cannot expand would be worse
 * than one that forgets which branches they closed.
 */
export function readCollapsed(
  store: CollapseStore | null,
  initiativeId: number,
  taskId: number,
): boolean {
  if (store === null) return false;
  try {
    return store.getItem(collapseKey(initiativeId, taskId)) === "1";
  } catch {
    return false;
  }
}

/** Writes a branch's state. A store that refuses is not worth failing a click. */
export function writeCollapsed(
  store: CollapseStore | null,
  initiativeId: number,
  taskId: number,
  collapsed: boolean,
): void {
  if (store === null) return;
  try {
    store.setItem(collapseKey(initiativeId, taskId), collapsed ? "1" : "0");
  } catch {
    // Nothing to do and nothing worth saying: the branch still toggled.
  }
}

/** One row on screen, in the order the eye reads them. */
export interface VisibleRow {
  readonly id: number;
  /** 0 for a top-level task, +1 per level — what drives the indent. */
  readonly depth: number;
}

/**
 * Every row the user can see, top to bottom. A collapsed branch still appears;
 * its descendants do not. This is the same list `visibleRows()` builds in the
 * `.TaskKeys` hook by filtering out anything inside a `ul.collapsed-peek` — the
 * difference is that this one is derived from the model, so it is right before
 * the DOM exists.
 */
export function visibleRows(
  model: TreeModel,
  collapsed: (id: number) => boolean,
): readonly VisibleRow[] {
  const rows: VisibleRow[] = [];

  const walk = (parentId: number, depth: number): void => {
    for (const id of childIdsOf(model, parentId)) {
      rows.push({ id, depth });
      if (!collapsed(id)) walk(id, depth + 1);
    }
  };

  walk(model.rootId, 0);
  return rows;
}

/** Just the ids, which is what the keyboard model works in. */
export function visibleIds(model: TreeModel, collapsed: (id: number) => boolean): readonly number[] {
  return visibleRows(model, collapsed).map((row) => row.id);
}

/**
 * Is this row on screen? Used by the deep link and by selection: a task inside a
 * collapsed branch has to be revealed before it can be scrolled to.
 */
export function isVisible(
  model: TreeModel,
  collapsed: (id: number) => boolean,
  id: number,
): boolean {
  return visibleRows(model, collapsed).some((row) => row.id === id);
}

/**
 * The collapsed branches standing between the root and `id` — what a deep link
 * has to open before the task it names can be seen. In outermost-first order,
 * which is also the order they have to be opened in.
 *
 * The task itself is never included: `/app/initiatives/5?task=9` reveals task 9,
 * it does not force 9's own children open and undo what the user collapsed.
 */
export function branchesToOpen(
  model: TreeModel,
  id: number,
  collapsed: (id: number) => boolean,
): readonly number[] {
  if (model.tasks[id] === undefined) return [];
  // `ancestors` walks upward; a deep link opens downward.
  return ancestors(model, id).filter(collapsed).reverse();
}

// --- Width (ProductSpec §6.2) ---------------------------------------------

/**
 * The narrowest a row is ever drawn, in px — `TREE_WIDTH_FLOOR_PX` in `app.js`,
 * and `min-w-[240px]` on the row itself. Past this the tree scrolls sideways
 * instead of squeezing the title.
 */
export const TREE_WIDTH_FLOOR_PX = 240;

/**
 * The `min-width` the tree's outer `<ul>` claims: the deepest visible row's
 * indent plus a whole row's worth of width. Every top-level row then stretches
 * to the same number, so the column has one edge rather than a ragged one, and
 * the scroll box scrolls horizontally when that exceeds the viewport.
 *
 * `indents` are each visible row's offset from the list's own left edge, in px,
 * measured from the laid-out DOM — measured, not assumed, because the indent
 * step is a Tailwind class that changes at the `sm:` breakpoint.
 */
export function treeMinWidth(indents: readonly number[]): number {
  let deepest = 0;
  for (const indent of indents) if (indent > deepest) deepest = indent;
  return Math.ceil(deepest + TREE_WIDTH_FLOOR_PX);
}

/** The same number as a CSS length, which is what the style attribute wants. */
export function treeMinWidthStyle(indents: readonly number[]): string {
  return `${treeMinWidth(indents)}px`;
}

export interface ScrollEdges {
  /** Scrolled down from the very top: the top fade shows. */
  readonly scrolled: boolean;
  /** At (or unable to reach) the bottom: the bottom fade hides. */
  readonly atEnd: boolean;
}

/**
 * The scroll-fade state, from a scroll box's three numbers. A 1px slack absorbs
 * sub-pixel rounding, exactly as `Hooks.TreeScrollFade` does — without it a box
 * scrolled to the bottom can report one-third of a pixel short forever.
 */
export function scrollEdges(box: {
  scrollTop: number;
  clientHeight: number;
  scrollHeight: number;
}): ScrollEdges {
  return {
    scrolled: box.scrollTop > 0,
    atEnd: box.scrollTop + box.clientHeight >= box.scrollHeight - 1,
  };
}
