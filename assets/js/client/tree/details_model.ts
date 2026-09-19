// The Details pane, decided (m04.02 item 3.4.3).
//
// Everything `details.tsx` needs to know that is not markup: which fields are
// enabled for this member on this task, what the progress block shows, the
// option lists the two assignee selects draw, the co-assignee arithmetic, and
// what an edit actually commits. It is a port of the decisions `task_editor/1`
// makes in HEEx — same rules, same copy — kept pure so they can be tested
// against the model without a DOM.
//
// The pane opens from the model and nothing else: every value here is read off
// the record and the members index the tree already holds, so a selection
// shows its fields at the click, never a round trip later (guardrails §6).

import type { Priority, SortMode } from "../api/types.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { childIdsOf } from "./model.ts";
import type { Permissions } from "./permissions.ts";
import { canProgress } from "./permissions.ts";
import type { RowUser } from "./row_model.ts";
import { resolveSort } from "./sort.ts";

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

const two = (n: number): string => String(n).padStart(2, "0");

/**
 * The "Last updated by" line's time: the template's `%b %-d %H:%M` in the
 * viewer's local time, as `<.local_time>` renders it. An unreadable or missing
 * timestamp gives an empty string rather than "Invalid Date".
 */
export function updatedAtText(iso: string | null): string {
  if (iso === null) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return `${MONTHS[date.getMonth()]} ${date.getDate()} ${two(date.getHours())}:${two(date.getMinutes())}`;
}

/**
 * The line's hover title: the full local instant, as `LocalTime.from_utc/1`
 * prints it (`YYYY-MM-DD HH:MM:SS`).
 */
export function updatedTitleText(iso: string | null): string {
  if (iso === null) return "";
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return (
    `${date.getFullYear()}-${two(date.getMonth() + 1)}-${two(date.getDate())} ` +
    `${two(date.getHours())}:${two(date.getMinutes())}:${two(date.getSeconds())}`
  );
}

/** `DoIt.Tasks.Task.priorities/0`, in the select's order. */
export const PRIORITIES: readonly Priority[] = ["low", "normal", "high"];

/** The dropdown's order: criteria first, then Manual at the bottom. */
export const SORT_MODE_OPTIONS: readonly SortMode[] = [
  "alphabetical",
  "completion",
  "priority",
  "created",
  "updated",
  "manual",
];

/** `sort_mode_label/1`. */
export function sortModeLabel(mode: SortMode): string {
  switch (mode) {
    case "manual":
      return "Manual";
    case "alphabetical":
      return "Alphabetical";
    case "completion":
      return "Completion %";
    case "priority":
      return "Priority";
    case "created":
      return "First Created";
    case "updated":
      return "Last Updated";
  }
}

/** `sort_direction_label/2` — the direction folded into the wording. */
function sortDirectionLabel(mode: SortMode, reverse: boolean): string {
  switch (mode) {
    case "alphabetical":
      return reverse ? "Alphabetical Z–A" : "Alphabetical A–Z";
    case "priority":
      return reverse ? "lowest priority" : "highest priority";
    case "completion":
      return reverse ? "most complete" : "least complete";
    case "created":
      return reverse ? "newest 1st" : "oldest 1st";
    case "updated":
      return reverse ? "stalest" : "recently updated";
    case "manual":
      return sortModeLabel(mode);
  }
}

/**
 * `sort_mode_inherit_label/1`: what the Inherit option reads — the sort the
 * task's ancestors resolve to, ignoring the task's own explicit mode.
 */
export function inheritLabel(model: TreeModel, id: number): string {
  const record = model.tasks[id];
  const [mode, reverse] =
    record === undefined ? (["manual", false] as const) : resolveSort(model, record.parent_id);
  return `Inherit (${sortDirectionLabel(mode, reverse)})`;
}

/** `reverse_disabled?/1`: Reverse means nothing on Inherit or Manual. */
export function reverseDisabled(mode: SortMode | null): boolean {
  return mode === null || mode === "manual";
}

/** `leaf?/1`, off the model's structure rather than the record's flag. */
export function isLeaf(model: TreeModel, id: number): boolean {
  return childIdsOf(model, id).length === 0;
}

/** Which controls this member may use on this task. */
export interface DetailsFields {
  /** Title, description, priority, sort, co-assignee controls, Delete, the link button. */
  readonly edit: boolean;
  /** The primary assignee select (`can_edit or can_staff`). */
  readonly assignee: boolean;
  /** The progress slider (`can_progress and leaf?`). */
  readonly progress: boolean;
  /** The co-assignees block is drawn at all (`can_edit or can_staff or links != []`). */
  readonly coAssignees: boolean;
}

/**
 * The enable rules `task_editor/1` applies. The client has no staffing pool —
 * `viewer_plus` is not in the tree read — so `can_staff` is `can_edit` here,
 * and a viewer sees the staffing controls disabled the way they do on any
 * task they do not lead.
 */
export function fieldsFor(
  model: TreeModel,
  record: TaskRecord,
  permissions: Permissions,
): DetailsFields {
  const edit = permissions.canEdit;
  return {
    edit,
    assignee: edit,
    progress: canProgress(permissions, record.id) && isLeaf(model, record.id),
    coAssignees: edit || record.co_assignee_ids.length > 0,
  };
}

/** The progress block: one layout for leaf and branch alike (§1.1). */
export interface ProgressView {
  readonly leaf: boolean;
  /** The readout and the slider's value: the leaf's own input, or the roll-up. */
  readonly value: number;
  /** "Computed from children" — the roll-up, whatever the task is. */
  readonly computed: number;
  readonly ariaLabel: string;
}

export function progressView(model: TreeModel, record: TaskRecord): ProgressView {
  const leaf = isLeaf(model, record.id);
  return {
    leaf,
    value: leaf ? (record.manual_progress ?? 0) : record.progress,
    computed: record.progress,
    ariaLabel: leaf ? "Manual progress" : "Manual progress (disabled — computed from subtasks)",
  };
}

/** `assignable_members/4` for an editor: everyone, in members order. */
export function assigneeOptions(members: ReadonlyMap<number, RowUser>): readonly RowUser[] {
  return [...members.values()];
}

/** `eligible_co_members/2`: not the primary, not already on the list. */
export function coAssigneeOptions(
  record: TaskRecord,
  members: ReadonlyMap<number, RowUser>,
): readonly RowUser[] {
  const taken = new Set(record.co_assignee_ids);
  return [...members.values()].filter(
    (user) => user.id !== record.assignee_id && !taken.has(user.id),
  );
}

/** One row of the co-assignee list. */
export interface CoRow {
  readonly id: number;
  /** `null` when they have left: the client holds only current members. */
  readonly user: RowUser | null;
  readonly first: boolean;
  readonly last: boolean;
}

export function coRows(record: TaskRecord, members: ReadonlyMap<number, RowUser>): readonly CoRow[] {
  const ids = record.co_assignee_ids;
  return ids.map((id, index) => ({
    id,
    user: members.get(id) ?? null,
    first: index === 0,
    last: index === ids.length - 1,
  }));
}

/** The list with `userId` one step up or down; `null` when it cannot move. */
export function moveCoAssignee(
  ids: readonly number[],
  userId: number,
  dir: "up" | "down",
): number[] | null {
  const from = ids.indexOf(userId);
  if (from === -1) return null;
  const to = dir === "up" ? from - 1 : from + 1;
  if (to < 0 || to >= ids.length) return null;
  const next = [...ids];
  const other = next[to];
  if (other === undefined) return null;
  next[to] = userId;
  next[from] = other;
  return next;
}

export function removeCoAssignee(ids: readonly number[], userId: number): number[] {
  return ids.filter((id) => id !== userId);
}

/** Appended at the end — position is promotion order. Already listed: unchanged. */
export function addCoAssignee(ids: readonly number[], userId: number): number[] {
  return ids.includes(userId) ? [...ids] : [...ids, userId];
}

/** The fields an edit can change, with the value a control hands back. */
export type EditableFields = Partial<
  Pick<TaskRecord, "title" | "description" | "priority" | "assignee_id" | "manual_progress">
>;

/**
 * What a committed title becomes: trimmed, and `null` when nothing changed or
 * the field was cleared — a blank title is refused server-side, so the pane
 * shows the kept value again rather than asking for a refusal.
 */
export function titleEdit(record: TaskRecord, draft: string): EditableFields | null {
  const title = draft.trim();
  if (title === "" || title === record.title) return null;
  return { title };
}

/** A cleared description is `null`, as the record keeps it. */
export function descriptionEdit(record: TaskRecord, draft: string): EditableFields | null {
  const description = draft === "" ? null : draft;
  if (description === (record.description ?? null)) return null;
  return { description };
}

export function priorityEdit(record: TaskRecord, value: string): EditableFields | null {
  const priority = PRIORITIES.find((p) => p === value);
  if (priority === undefined || priority === record.priority) return null;
  return { priority };
}

/** The select's `""` is Unassigned. */
export function assigneeEdit(record: TaskRecord, value: string): EditableFields | null {
  const assignee_id = value === "" ? null : Number.parseInt(value, 10);
  if (assignee_id !== null && !Number.isInteger(assignee_id)) return null;
  if (assignee_id === record.assignee_id) return null;
  return { assignee_id };
}

/** The slider's value, clamped to 0..100 and snapped to its step of 5. */
export function progressEdit(record: TaskRecord, value: string): EditableFields | null {
  const raw = Number.parseInt(value, 10);
  if (!Number.isInteger(raw)) return null;
  const manual_progress = Math.min(100, Math.max(0, Math.round(raw / 5) * 5));
  if (manual_progress === record.manual_progress) return null;
  return { manual_progress };
}

/** The sort select's `""` is Inherit. */
export function sortModeFrom(value: string): SortMode | null {
  return SORT_MODE_OPTIONS.find((m) => m === value) ?? null;
}

/**
 * What the sort menu commits when the mode select changes: Reverse is dropped
 * the moment it means nothing, so a change to Inherit or Manual never carries a
 * stale `true` along.
 */
export function sortEdit(
  record: TaskRecord,
  mode: SortMode | null,
  reverse: boolean,
): { mode: SortMode | null; reverse: boolean } | null {
  const next = { mode, reverse: reverseDisabled(mode) ? false : reverse };
  if (next.mode === record.sort_mode && next.reverse === record.sort_reverse) return null;
  return next;
}

/**
 * The line under a field someone else is in (m04.03 4.1.2): "Ann is editing
 * this too." / "Ann and Bob are editing this too." Empty when nobody is.
 */
export function editingNotice(names: readonly string[]): string {
  if (names.length === 0) return "";
  if (names.length === 1) return `${names[0]} is editing this too.`;
  const head = names.slice(0, -1).join(", ");
  return `${head} and ${names[names.length - 1]} are editing this too.`;
}
