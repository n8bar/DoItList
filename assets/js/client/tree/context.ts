// Everything a row needs that is not the row (m04.02 items 2.1, 2.2).
//
// One object, built once per render by `tree.tsx` and handed down whole, rather
// than eighteen props threaded through every level of the nesting. It is plain
// data plus callbacks — no React, no DOM — so `row_model.ts` and
// `tree_model.ts` can be tested against the same shape the screen builds.

import type { SortMode } from "../api/types.ts";
import type { EditField } from "../live/presence_model.ts";
import type { RemoteChange } from "../live/refresh.ts";
import type { RowPreferences } from "../state/preferences.ts";
import type { TaskRecord } from "./model.ts";
import type { Permissions } from "./permissions.ts";
import type { RowUser } from "./row_model.ts";
import type { PresenceReader } from "./presence_store.ts";
import type { Collapsed } from "./collapse_model.ts";
import type { Selected } from "./selection_model.ts";
import type { TaskReader } from "./task_store.ts";

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
  /**
   * A drop: `parentId` / `position` as `drag_model.ts` planned them, and the
   * sibling it landed beside when there was one — the slot is re-read from
   * that sibling when the move is sent (m04.03 4.5).
   */
  | { kind: "move"; id: number; parentId: number; position: number | null; reorder: boolean; anchor?: MoveAnchor }
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

/** The sibling a drop landed beside, and which side of it. */
export interface MoveAnchor {
  readonly id: number;
  readonly side: "before" | "after";
}

/**
 * A Details-pane edit the server refused (item 5.2.3): the fields as the user
 * typed them, kept in the pane with the server's sentence beside them and the
 * two ways out, Retry and Discard (m04.03 4.6.2). `key` names the journal
 * record that keeps it across a reload.
 */
export interface EditRejection {
  readonly key: string;
  readonly id: number;
  readonly fields: Extract<TreeIntent, { kind: "edit" }>["fields"];
  readonly message: string;
}

/** Someone else's writes as they land (`InitiativeSync.onRemoteChange`), for the pane's focused field (m04.03 4.2). */
export interface RemoteChangeSource {
  subscribe(listener: (change: RemoteChange) => void): () => void;
}

/** Where an add form is being opened from. */
export type AddAnchor =
  | { kind: "root" }
  | { kind: "child"; taskId: number }
  | { kind: "sibling"; taskId: number };

export interface TreeContext {
  /**
   * The model, read by each row and each children list for itself (item
   * 7.18) — like `selection`, `collapse` and `presence`, a reader rather than
   * a value, so a write re-renders the rows it changed and not the tree. The
   * pending marks (pink rows, indeterminate bars, stand-in keys) and the
   * refused pane edit come through it too.
   */
  readonly tasks: TaskReader;
  readonly initiativeId: number;
  readonly permissions: Permissions;
  /** The account's row-display choices. */
  readonly rows: RowPreferences;
  /** Members by user id, for the avatars. */
  readonly members: ReadonlyMap<number, RowUser>;
  /**
   * Other members' selections and who is online, read by each row for its
   * own badges and dot (item 7.17). Not a value: a value here gave the context
   * a new identity on every presence echo — this window's own selection
   * included — and re-rendered every row for a change no row could see.
   */
  readonly presence: PresenceReader;
  /**
   * The selected task, read by each row for itself (item 2.2.3). Not a value:
   * a value here would give the context a new identity on every selection
   * and re-render every row for a change that touches two.
   */
  readonly selection: Selected;
  canProgress(id: number): boolean;
  /**
   * The closed branches, read by each branch for itself (item 7.9.1) — like
   * `selection`, a reader rather than a value, so a toggle re-renders the one
   * branch it concerns and not the tree.
   */
  readonly collapse: Collapsed;
  onToggleCollapse(id: number): void;
  /** Select `id`, or clear (`null`) — a click on the selected row clears it. */
  onSelect(id: number | null): void;
  /** Open the branches down to `id`, select it and scroll to it (a `%` reference). */
  onReveal(id: number): void;
  onOpenAdd(anchor: AddAnchor): void;
  onIntent(intent: TreeIntent): void;
  /** A touch swiped the handle instead of holding it: teach the gesture. */
  onDragHint?(): void;
  /**
   * The pane says which of its fields the user is in (`null` for none), for
   * presence (m04.03 4.1.1). Advisory: announced, never waited on.
   */
  onEditField?(field: EditField | null): void;
  /** Someone else's writes, as the pane's focused field needs them (4.2). */
  readonly remoteChanges?: RemoteChangeSource;
  /** Retry a refused pane edit as a new submission (4.6.2); the row goes pending at once. */
  onRetryEdit?(rejection: EditRejection): void;
  /** Drop a refused pane edit: the field shows canonical and the record goes. */
  onDiscardEdit?(rejection: EditRejection): void;
}
