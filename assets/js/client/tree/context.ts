// Everything a row needs that is not the row (m04.02 items 2.1, 2.2).
//
// One object, built once per render by `tree.tsx` and handed down whole, rather
// than eighteen props threaded through every level of the nesting. It is plain
// data plus callbacks — no React, no DOM — so `row_model.ts` and
// `tree_model.ts` can be tested against the same shape the screen builds.

import type { ProgressCalc, SortMode } from "../api/types.ts";
import type { RowPreferences } from "../state/preferences.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import type { Permissions } from "./permissions.ts";
import type { RowPresence, RowUser } from "./row_model.ts";

/** A write the user asked for. Arc 3's adapter is what eventually answers one. */
export type TreeIntent =
  | { kind: "toggleComplete"; id: number; done: boolean }
  | { kind: "cascadeComplete"; id: number; done: boolean }
  /** Alt + arrows: reorder within the siblings, or change depth. */
  | { kind: "reorder"; id: number; dir: "up" | "down" }
  | { kind: "indent"; id: number }
  | { kind: "outdent"; id: number }
  /** P / A stepped a value; `back` is the Shift direction. */
  | { kind: "step"; id: number; field: "priority" | "assignee"; back: boolean }
  | { kind: "delete"; id: number }
  /** A drop: `parentId` / `position` as `drag_model.ts` planned them. */
  | { kind: "move"; id: number; parentId: number; position: number | null; reorder: boolean }
  /** The Details pane committed one field (item 3.4.3). */
  | {
      kind: "edit";
      id: number;
      fields: Partial<
        Pick<TaskRecord, "title" | "description" | "priority" | "assignee_id" | "manual_progress">
      >;
    }
  /** The whole co-assignee list, in promotion order. */
  | { kind: "coAssignees"; id: number; ids: number[] }
  /** `null` mode is Inherit. */
  | { kind: "setSort"; id: number; mode: SortMode | null; reverse: boolean }
  /** "Make descendants inherit" — `cascade_sort`. */
  | { kind: "cascadeSort"; id: number };

/** Where an add form is being opened from. */
export type AddAnchor =
  | { kind: "root" }
  | { kind: "child"; taskId: number }
  | { kind: "sibling"; taskId: number };

export interface TreeContext {
  readonly model: TreeModel;
  readonly initiativeId: number;
  readonly progressCalc: ProgressCalc;
  readonly permissions: Permissions;
  /** The account's row-display choices. */
  readonly rows: RowPreferences;
  /** Members by user id, for the avatars. */
  readonly members: ReadonlyMap<number, RowUser>;
  /** Other members' selections and who is online, for the badges and dots. */
  readonly presence: RowPresence;
  readonly selectedTaskId: number | null;
  /** Rows with a write in flight — painted pink. Arc 3 fills these. */
  readonly savingIds: ReadonlySet<number>;
  /** Rows whose roll-up is being recomputed — indeterminate bars. */
  readonly recomputingIds: ReadonlySet<number>;

  canProgress(id: number): boolean;
  collapsed(id: number): boolean;
  onToggleCollapse(id: number): void;
  onSelect(id: number): void;
  onOpenAdd(anchor: AddAnchor): void;
  onIntent(intent: TreeIntent): void;
  /** A touch swiped the handle instead of holding it: teach the gesture. */
  onDragHint?(): void;
}
