// The task tree (m04.02 items 2.2.1, 2.2.2, 2.2.6, 3.3.2, 3.3.3).
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
//   * DragReorder — `drag.tsx` owns the gesture; this file only mounts the
//     drop zones it needs (root top / bottom, each open branch's tail) while
//     a drag is on, so they cost nothing the rest of the time.
// The workspace's other tree hook, TreeScrollFade, has no counterpart here on
// purpose: it fades the top and bottom of the tree's OWN vertical scroll box,
// and the client has exactly one vertical scrolling region (`#client-scroll`).
// Nesting a second one inside it would trap the wheel and give the page two
// scrollbars, so the tree scrolls sideways only and the frame owns the rest.
//
// The arithmetic half lives in `tree_model.ts` and is tested there; what is left
// here is reading the DOM and writing the result back, which no unit test could
// reach anyway.

import type { ReactNode } from "react";
import { useCallback, useEffect, useLayoutEffect, useRef } from "react";

import { childIdsOf } from "./model.ts";
import { resolveSort } from "./sort.ts";
import type { AddRequest, AddSlot } from "./add_form_model.ts";
import { sameSlot } from "./add_form_model.ts";
import { AddForm } from "./add_form.tsx";
import type { TreeContext } from "./context.ts";
import { RootZone, TailZone, useTreeDrag } from "./drag.tsx";
import { Icon } from "../ui/icon.tsx";
import { Row } from "./row.tsx";
import { treeMinWidthStyle } from "./tree_model.ts";

export interface TreeProps {
  ctx: TreeContext;
  /** The one open add form, or null. One at a time, like the LiveView. */
  addSlot: AddSlot | null;
  addTitle: string;
  onAddTitleChange: (title: string) => void;
  onAddMove: (dir: -1 | 1) => void;
  onAddClose: () => void;
  onAdd: (request: AddRequest) => void;
  /**
   * Undo / redo (the workspace's `#undo-button` / `#redo-button`). `busy` is
   * the one in flight, if any — the button says so until the reply lands.
   */
  history?: HistoryControls;
}

export interface HistoryControls {
  busy: "undo" | "redo" | null;
  onHistory: (action: "undo" | "redo") => void;
}

const HISTORY_BUTTON =
  "inline-flex items-center justify-center w-7 h-7 rounded text-zinc-500 hover:text-zinc-800 hover:bg-zinc-100 dark:text-zinc-400 dark:hover:text-zinc-100 dark:hover:bg-zinc-800 disabled:opacity-30 disabled:pointer-events-none transition";

/** One of the two history buttons, latched to its in-flight look while it waits. */
function HistoryButton({
  action,
  history,
}: {
  action: "undo" | "redo";
  history: HistoryControls;
}) {
  const label = action === "undo" ? "Undo" : "Redo";
  const busy = history.busy === action;
  return (
    <button
      type="button"
      id={`${action}-button`}
      disabled={history.busy !== null}
      aria-busy={busy}
      title={busy ? `${label}…` : label}
      aria-label={busy ? `${label}…` : label}
      onClick={() => history.onHistory(action)}
      className={HISTORY_BUTTON}
    >
      <Icon
        name={busy ? "arrow-path" : action === "undo" ? "arrow-uturn-left" : "arrow-uturn-right"}
        spin={busy}
        className="w-4 h-4"
      />
    </button>
  );
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

/** One branch's children, or nothing at all when it has none. */
function Children({
  ctx,
  parentId,
  depth,
  slot,
  form,
  dragging,
}: {
  ctx: TreeContext;
  parentId: number;
  depth: number;
  slot: AddSlot | null;
  form: (anchor: AddSlot) => ReactNode;
  dragging: boolean;
}) {
  const childIds = childIdsOf(ctx.model, parentId);
  if (childIds.length === 0) return null;

  return (
    <ul
      id={`children-${parentId}`}
      data-task-id={parentId}
      data-initiative-id={ctx.initiativeId}
      data-sort-mode={resolveSort(ctx.model, parentId)[0]}
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
        <Branch
          key={ctx.rowKeys?.get(id) ?? id}
          ctx={ctx}
          id={id}
          depth={depth}
          slot={slot}
          form={form}
          dragging={dragging}
        />
      ))}
      {/* "Last child of this branch" — only reachable while the branch is open,
          so a closed one gets no strip at all. */}
      {dragging && !ctx.collapsed(parentId) && <TailZone branchId={parentId} />}
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
  dragging,
}: {
  ctx: TreeContext;
  id: number;
  depth: number;
  slot: AddSlot | null;
  form: (anchor: AddSlot) => ReactNode;
  dragging: boolean;
}) {
  const childSlot: AddSlot = { kind: "child", taskId: id };
  const siblingSlot: AddSlot = { kind: "sibling", taskId: id };

  return (
    <>
      <Row ctx={ctx} id={id} depth={depth}>
        {sameSlot(slot, childSlot) && <div className="px-3 pb-3">{form(childSlot)}</div>}
        <Children ctx={ctx} parentId={id} depth={depth + 1} slot={slot} form={form} dragging={dragging} />
      </Row>
      {/* "Add sibling" opens BELOW the row it was opened from, as its own list
          item, so the new task appears where it will actually land. */}
      {sameSlot(slot, siblingSlot) && <li>{form(siblingSlot)}</li>}
    </>
  );
}

export function Tree({
  ctx,
  addSlot,
  addTitle,
  onAddTitleChange,
  onAddMove,
  onAddClose,
  onAdd,
  history,
}: TreeProps) {
  const box = useRef<HTMLDivElement | null>(null);
  const list = useRef<HTMLUListElement | null>(null);

  useTreeWidth(list);
  const dragging = useTreeDrag(ctx, list);

  const form = useCallback(
    (anchor: AddSlot) => (
      <AddForm
        model={ctx.model}
        slot={anchor}
        title={addTitle}
        onTitleChange={onAddTitleChange}
        onMove={onAddMove}
        onClose={onAddClose}
        onAdd={onAdd}
      />
    ),
    [addTitle, ctx.model, onAdd, onAddClose, onAddMove, onAddTitleChange],
  );

  const rootIds = childIdsOf(ctx.model, ctx.model.rootId);
  const rootSlot: AddSlot = { kind: "root" };

  return (
    <div className="relative">
      {/* The workspace's New List control, same wording and same `data-add-root`
          hook. Outside the scroll box, as the LiveView keeps it (it lives in
          `initiative_header/1`): scrolling a deep tree sideways must not carry
          the only way in off the screen with it. Without this control a tree
          with no rows has no way in at all — N and S both need a selection. */}
      {ctx.permissions.canEdit && (
        <div className="mb-3 flex">
          <button
            type="button"
            data-add-root
            onClick={() => ctx.onOpenAdd(rootSlot)}
            aria-label="New list"
            title="New list"
            className="inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
          >
            <Icon name="plus" className="w-4 h-4" />
            <span>New List</span>
          </button>
          {/* Undo / Redo, as the workspace header carries them (m02.06 item 5):
              Ctrl+Z / Ctrl+Shift+Z drive the same handlers. */}
          {history !== undefined && (
            <div className="ml-auto flex items-center gap-1">
              <HistoryButton action="undo" history={history} />
              <HistoryButton action="redo" history={history} />
            </div>
          )}
        </div>
      )}

      {/* Horizontal scroll only. The client has ONE vertical scrolling region —
          `#client-scroll` in the frame — and a second one nested inside it would
          trap the wheel, break the router's scroll restoration and give the page
          two scrollbars. Deep indentation still scrolls sideways here, which is
          what ProductSpec §6.2 asks for. */}
      <div ref={box} id="tree-scroll" className="min-w-0 overflow-x-auto">
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
          {dragging && <RootZone zone="top" />}
          {/* Keyed by the id the row was FIRST drawn under: an added row keeps
              its stand-in key once the server names it, so nothing remounts. */}
          {rootIds.map((id) => (
            <Branch
              key={ctx.rowKeys?.get(id) ?? id}
              ctx={ctx}
              id={id}
              depth={0}
              slot={addSlot}
              form={form}
              dragging={dragging}
            />
          ))}
          {dragging && <RootZone zone="bottom" />}
        </ul>

      </div>
    </div>
  );
}
