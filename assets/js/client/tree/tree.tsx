// The task tree (m04.02 items 2.2.1, 2.2.2, 2.2.6).
//
// Nested `<ul>/<li>` built from the model's `childIds`, keyed by task id: the
// root's children are the top level, and every branch's children are a list
// inside its own `<li>`. The shape is the LiveView's `task_node/1` shape on
// purpose — `assets/css/app.css` is shared, and rules like `ul.collapsed-peek`
// and `li[data-selected] > [data-task-row]` only bite if the markup matches.
//
// Two behaviours the LiveView does with hooks are done here with measurements
// rather than DOM patching:
//
//   * TreeWidth — the tree is at least as wide as its deepest visible row plus
//     a whole row, so a deep branch scrolls horizontally instead of squashing
//     the rows into a column of wrapped words (ProductSpec §6.2). Measured off
//     the rendered rows, because the indent is CSS padding, not a number the
//     model knows.
//   * TreeScrollFade — the top/bottom gradients that say "there is more above
//     / below". The CSS reads `data-scrolled` / `data-at-end` off the frame.
//
// Both arithmetic halves live in `tree_model.ts` and are tested there; what is
// left here is reading the DOM and writing the result back, which no unit test
// could reach anyway.

import type { ReactNode } from "react";
import { useCallback, useEffect, useLayoutEffect, useRef } from "react";

import { childIdsOf } from "./model.ts";
import type { AddRequest, AddSlot } from "./add_form_model.ts";
import { sameSlot } from "./add_form_model.ts";
import { AddForm } from "./add_form.tsx";
import type { TreeContext } from "./context.ts";
import { Row } from "./row.tsx";
import { scrollEdges, treeMinWidthStyle } from "./tree_model.ts";

export interface TreeProps {
  ctx: TreeContext;
  /** The one open add form, or null. One at a time, like the LiveView. */
  addSlot: AddSlot | null;
  onAddMove: (dir: -1 | 1) => void;
  onAddClose: () => void;
  onAdd: (request: AddRequest) => void;
}

/** Keeps the tree at least as wide as its deepest visible row. */
function useTreeWidth(ref: React.RefObject<HTMLUListElement | null>): void {
  const recompute = useCallback(() => {
    const ul = ref.current;
    if (ul === null) return;

    const left = ul.getBoundingClientRect().left;
    const indents: number[] = [];
    for (const row of ul.querySelectorAll("[data-task-row]")) {
      // A row inside a collapsed branch is clipped to a sliver; it must not
      // decide how wide the tree is.
      if (row.closest("ul.collapsed-peek") !== null) continue;
      // Relative to the list, so the answer does not change as it scrolls.
      indents.push(row.getBoundingClientRect().left - left);
    }

    const next = treeMinWidthStyle(indents);
    if (ul.style.minWidth !== next) ul.style.minWidth = next;
  }, [ref]);

  // After layout, every render: rows appear, collapse, and re-indent without
  // any dependency this component could list.
  useLayoutEffect(recompute);

  useEffect(() => {
    window.addEventListener("resize", recompute);
    return () => window.removeEventListener("resize", recompute);
  }, [recompute]);
}

/** Flips the frame's fade attributes from the scroll box's geometry. */
function useScrollFades(
  box: React.RefObject<HTMLDivElement | null>,
  frame: React.RefObject<HTMLDivElement | null>,
): void {
  const recompute = useCallback(() => {
    const el = box.current;
    const parent = frame.current;
    if (el === null || parent === null) return;

    const edges = scrollEdges(el);
    parent.toggleAttribute("data-scrolled", edges.scrolled);
    parent.toggleAttribute("data-at-end", edges.atEnd);
  }, [box, frame]);

  useLayoutEffect(recompute);

  useEffect(() => {
    const el = box.current;
    if (el === null) return;
    el.addEventListener("scroll", recompute, { passive: true });
    window.addEventListener("resize", recompute);
    return () => {
      el.removeEventListener("scroll", recompute);
      window.removeEventListener("resize", recompute);
    };
  }, [box, recompute]);
}

/** One branch's children, or nothing at all when it has none. */
function Children({
  ctx,
  parentId,
  depth,
  slot,
  form,
}: {
  ctx: TreeContext;
  parentId: number;
  depth: number;
  slot: AddSlot | null;
  form: (anchor: AddSlot) => ReactNode;
}) {
  const childIds = childIdsOf(ctx.model, parentId);
  if (childIds.length === 0) return null;

  return (
    <ul
      id={`children-${parentId}`}
      data-task-id={parentId}
      data-initiative-id={ctx.initiativeId}
      className={[
        "pl-1.5 sm:pl-6 space-y-1",
        // The 6px sliver that says "there is work under me" — the same class
        // the LiveView's collapse toggle sets, so one CSS rule serves both.
        ctx.collapsed(parentId) ? "collapsed-peek" : "",
      ]
        .filter((part) => part !== "")
        .join(" ")}
    >
      {childIds.map((id) => (
        <Branch key={id} ctx={ctx} id={id} depth={depth} slot={slot} form={form} />
      ))}
    </ul>
  );
}

/** One task: its row, its add slot, its children. */
function Branch({
  ctx,
  id,
  depth,
  slot,
  form,
}: {
  ctx: TreeContext;
  id: number;
  depth: number;
  slot: AddSlot | null;
  form: (anchor: AddSlot) => ReactNode;
}) {
  const childSlot: AddSlot = { kind: "child", taskId: id };
  const siblingSlot: AddSlot = { kind: "sibling", taskId: id };

  return (
    <>
      <Row ctx={ctx} id={id} depth={depth}>
        {sameSlot(slot, childSlot) && <div className="px-3 pb-3">{form(childSlot)}</div>}
        <Children ctx={ctx} parentId={id} depth={depth + 1} slot={slot} form={form} />
      </Row>
      {/* "Add sibling" opens BELOW the row it was opened from, as its own list
          item, so the new task appears where it will actually land. */}
      {sameSlot(slot, siblingSlot) && <li>{form(siblingSlot)}</li>}
    </>
  );
}

export function Tree({ ctx, addSlot, onAddMove, onAddClose, onAdd }: TreeProps) {
  const frame = useRef<HTMLDivElement | null>(null);
  const box = useRef<HTMLDivElement | null>(null);
  const list = useRef<HTMLUListElement | null>(null);

  useTreeWidth(list);
  useScrollFades(box, frame);

  const form = useCallback(
    (anchor: AddSlot) => (
      <AddForm
        model={ctx.model}
        slot={anchor}
        onMove={onAddMove}
        onClose={onAddClose}
        onAdd={onAdd}
      />
    ),
    [ctx.model, onAdd, onAddClose, onAddMove],
  );

  const rootIds = childIdsOf(ctx.model, ctx.model.rootId);
  const rootSlot: AddSlot = { kind: "root" };

  return (
    <div ref={frame} className="relative lg:flex-1 lg:min-h-0 group/treescroll" data-at-end>
      <div
        ref={box}
        id="tree-scroll"
        className="min-w-0 overflow-x-auto lg:h-full lg:overflow-y-auto"
      >
        {/* Sticky inside the scroll box, so the scrollport bounds it past both
            scrollbars with no measurement. Decorative and click-through. */}
        <div
          aria-hidden="true"
          className="hidden lg:block pointer-events-none sticky top-0 left-0 -mb-24 w-full h-24 z-10 bg-gradient-to-b from-white dark:from-zinc-950 to-transparent opacity-0 transition-opacity duration-150 group-data-scrolled/treescroll:opacity-100"
        />

        {sameSlot(addSlot, rootSlot) && <div className="mb-3">{form(rootSlot)}</div>}

        {rootIds.length === 0 && (
          <div className="text-zinc-500 dark:text-zinc-400 text-sm">
            {ctx.permissions.canEdit
              ? "No lists yet. Use the New List button above to start tracking work."
              : "No lists yet."}
          </div>
        )}

        <ul
          ref={list}
          id="task-tree"
          data-progress-calc={ctx.progressCalc}
          className="space-y-2"
        >
          {rootIds.map((id) => (
            <Branch key={id} ctx={ctx} id={id} depth={0} slot={addSlot} form={form} />
          ))}
        </ul>

        <div
          aria-hidden="true"
          className="hidden lg:block pointer-events-none sticky bottom-0 left-0 -mt-24 w-full h-24 z-10 bg-gradient-to-t from-white dark:from-zinc-950 to-transparent opacity-100 transition-opacity duration-150 group-data-at-end/treescroll:opacity-0"
        />
      </div>
    </div>
  );
}
