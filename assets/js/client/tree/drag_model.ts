// Where a dragged row would land (m04.02 item 3.3.1).
//
// The gesture layer measures — which row is under the pointer, how far down
// it, whether a root zone or a branch's tail strip was hit — and this module
// decides what that means: which band of the row, which parent and slot the
// move would go to, and whether the drop is allowed at all. It is the
// `DragReorder` hook's `bandFor`, `siblingPosition`, `lastChildPosition` and
// `updateDropTarget` with the DOM taken out, so every rule can be tested with
// numbers and a model rather than a browser.
//
// Rules, unchanged from the hook:
//
//  * a row has thin edge strips (above / below) and a wide center (reparent,
//    appended as last child); an expanded branch has no below strip — its
//    tail zone is how you say "last child";
//  * the root top / bottom overlay zones beat row anchoring: front or end of
//    the root list, flagged reorder;
//  * a branch's tail zone appends to that branch, flagged reorder;
//  * the source, anything under it, and no row at all are not targets;
//  * a center drop onto the source's own parent is a no-op shown as forbidden,
//    while that row's edge strips still reorder around the parent.

import { childIdsOf, subtreeIds } from "./model.ts";
import type { TreeModel } from "./model.ts";

/** Px strip at each edge of a row that reads as above / below. */
export const EDGE_PX = 9;

export type Band = "above" | "center" | "below";

/** The `move_task` the drop would send: parent, slot, and the manual-sort pin. */
export interface DropPlan {
  readonly parentId: number;
  /** `null` appends. */
  readonly position: number | null;
  readonly reorder: boolean;
}

/** What is under the pointer, as the gesture layer measured it. */
export type DropHit =
  | { kind: "none" }
  | { kind: "zone"; zone: "top" | "bottom" }
  | { kind: "tail"; branchId: number }
  | { kind: "row"; anchorId: number; band: Band };

/** What to show and, when the drop is allowed, what it would do. */
export type DropTarget =
  | { kind: "none" }
  | { kind: "forbidden"; anchorId: number }
  | { kind: "zone"; zone: "top" | "bottom"; plan: DropPlan }
  | { kind: "tail"; branchId: number; plan: DropPlan }
  | { kind: "reparent"; anchorId: number; plan: DropPlan }
  | { kind: "placeholder"; anchorId: number; band: Band; plan: DropPlan };

/**
 * Which band of a row `clientY` is in, measured against the row strip only,
 * not its subtree. `expandedWithChildren` is the hook's `hasVisibleChildren`:
 * true removes the below strip, so the bottom of an open branch reparents.
 */
export function bandFor(
  rowTop: number,
  rowHeight: number,
  clientY: number,
  expandedWithChildren: boolean,
): Band {
  if (clientY < rowTop + EDGE_PX) return "above";
  if (!expandedWithChildren && clientY >= rowTop + rowHeight - EDGE_PX) return "below";
  return "center";
}

/**
 * 0-based slot for a sibling reorder above or below `anchorId`, in the
 * server's terms: an index into the destination sibling list EXCLUDING the
 * source. When the source sits earlier in that same list, removing it shifts
 * the anchor down by one.
 */
export function siblingPosition(
  model: TreeModel,
  sourceId: number,
  anchorId: number,
  band: "above" | "below",
): number {
  const anchor = model.tasks[anchorId];
  const siblings = anchor === undefined ? [] : childIdsOf(model, anchor.parent_id);
  const anchorIdx = siblings.indexOf(anchorId);
  const sourceIdx = siblings.indexOf(sourceId);
  let base = Math.max(anchorIdx, 0);
  if (sourceIdx !== -1 && sourceIdx < anchorIdx) base -= 1;
  return band === "above" ? base : base + 1;
}

/**
 * Slot that appends the source as `branchId`'s last child: its child count,
 * less one when the source is already among them.
 */
export function lastChildPosition(model: TreeModel, sourceId: number, branchId: number): number {
  const kids = childIdsOf(model, branchId);
  return kids.includes(sourceId) ? kids.length - 1 : kids.length;
}

/** Whether `id` is the source or anything under it. */
export function withinSource(model: TreeModel, sourceId: number, id: number): boolean {
  return subtreeIds(model, sourceId).includes(id);
}

/** Turns a measured hit into the drop it means for `sourceId`. */
export function resolveDrop(
  model: TreeModel,
  args: { sourceId: number; hit: DropHit },
): DropTarget {
  const { sourceId, hit } = args;
  const source = model.tasks[sourceId];
  if (source === undefined) return { kind: "none" };

  switch (hit.kind) {
    case "none":
      return { kind: "none" };

    case "zone":
      return {
        kind: "zone",
        zone: hit.zone,
        plan: {
          parentId: model.rootId,
          position: hit.zone === "top" ? 0 : null,
          reorder: true,
        },
      };

    case "tail": {
      const { branchId } = hit;
      if (model.tasks[branchId] === undefined) return { kind: "none" };
      if (withinSource(model, sourceId, branchId)) return { kind: "forbidden", anchorId: branchId };
      return {
        kind: "tail",
        branchId,
        plan: {
          parentId: branchId,
          position: lastChildPosition(model, sourceId, branchId),
          reorder: true,
        },
      };
    }

    case "row": {
      const { anchorId, band } = hit;
      const anchor = model.tasks[anchorId];
      if (anchor === undefined) return { kind: "none" };
      if (withinSource(model, sourceId, anchorId)) return { kind: "none" };

      if (band === "center") {
        if (anchorId === source.parent_id) return { kind: "forbidden", anchorId };
        return {
          kind: "reparent",
          anchorId,
          plan: { parentId: anchorId, position: null, reorder: false },
        };
      }

      return {
        kind: "placeholder",
        anchorId,
        band,
        plan: {
          parentId: anchor.parent_id,
          position: siblingPosition(model, sourceId, anchorId, band),
          reorder: true,
        },
      };
    }
  }
}
