// The Details pane (m04.02 item 3.4.3).
//
// A port of `task_editor/1` in `initiative_workspace_live.ex`, field for field
// and class for class: the layout IS the design. Everything the pane shows is
// read off the tree's own model and members index the instant a row is
// selected — opening never waits on the network (guardrails §6).
//
// Each field keeps a draft while the user is in it and commits ONE intent when
// they leave it (blur, or Enter on the title) or change it (selects, slider).
// Between edits the field shows the record, so a change that lands from the
// channel is what the user sees, not a stale copy. The intents are read-only
// until Worklist 5's adapter answers them.
//
// Comments, Activity and chat are Arc 7 — see the note at the end.

import type { ChangeEvent, KeyboardEvent, ReactNode, ToggleEvent } from "react";
import { useEffect, useRef, useState } from "react";

import { Icon } from "../ui/icon.tsx";
import type { TreeContext } from "./context.ts";
import {
  PRIORITIES,
  SORT_MODE_OPTIONS,
  addCoAssignee,
  assigneeEdit,
  assigneeOptions,
  coAssigneeOptions,
  coRows,
  descriptionEdit,
  fieldsFor,
  inheritLabel,
  moveCoAssignee,
  priorityEdit,
  progressEdit,
  progressView,
  removeCoAssignee,
  reverseDisabled,
  sortEdit,
  sortModeFrom,
  sortModeLabel,
  titleEdit,
} from "./details_model.ts";
import type { EditableFields } from "./details_model.ts";
import type { TaskRecord } from "./model.ts";
import type { RowUser } from "./row_model.ts";
import { avatarStyle, initials } from "./row_model.ts";

const LABEL = "text-xs text-zinc-500 dark:text-zinc-400";
const CO_MOVE =
  "px-1 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 disabled:opacity-30";

export interface TaskDetailsProps {
  ctx: TreeContext;
  id: number;
  /** The Close button. */
  onClose: () => void;
}

export function TaskDetails({ ctx, id, onClose }: TaskDetailsProps) {
  const record = ctx.model.tasks[id];
  if (record === undefined) return null;

  const fields = fieldsFor(ctx.model, record, ctx.permissions);
  const canEdit = fields.edit;
  const progress = progressView(ctx.model, record);
  const rows = coRows(record, ctx.members);
  const commit = (edit: EditableFields | null): void => {
    if (edit !== null) ctx.onIntent({ kind: "edit", id, fields: edit });
  };
  const commitCo = (ids: number[] | null): void => {
    if (ids !== null) ctx.onIntent({ kind: "coAssignees", id, ids });
  };

  return (
    <div className="space-y-4">
      <div className="flex items-start justify-between gap-2">
        <h3 className="font-medium text-zinc-800 dark:text-zinc-100">Task details</h3>
        <button
          type="button"
          data-close-task
          aria-label="Close"
          title="Close"
          onClick={onClose}
          className="hidden lg:inline-flex items-center justify-center w-7 h-7 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
        >
          <Icon name="x-mark" className="w-5 h-5" />
        </button>
      </div>

      {/* Pane field order (m02.05 item 15): title, description, progress,
          sorting, priority, assignee — so Assignee sits directly against the
          Co-assignees block below. */}
      <div className="space-y-3">
        <div>
          <div className="flex items-center justify-between gap-2">
            <label htmlFor="task-field-title" className={LABEL}>
              Title
            </label>
            {canEdit && <RefPickerButton target="#task-field-title" />}
          </div>
          <TitleField key={id} record={record} disabled={!canEdit} onCommit={commit} />
        </div>

        <div>
          <div className="flex items-center justify-between gap-2">
            <label htmlFor="task-field-description" className={LABEL}>
              Description
            </label>
            {canEdit && <RefPickerButton target="#task-field-description" />}
          </div>
          <DescriptionField key={id} record={record} disabled={!canEdit} onCommit={commit} />
        </div>

        {/* One progress block for leaf and branch alike — the branch-only copy
            keeps its space when invisible, so leaf↔branch selection switches
            never shift the layout (UX_GUARDRAILS 1.1). */}
        <div className="space-y-1">
          <div className="flex items-center gap-1">
            <label htmlFor="task-field-progress" className={LABEL}>
              Manual progress: <span data-progress-readout>{progress.value}</span>%
            </label>
            <span data-mp-hint className={`inline-flex${progress.leaf ? " invisible" : ""}`}>
              <InfoHint id={`mp-hint-${id}`} label="Why is this disabled?">
                Progress on a task with subtasks is calculated from its subtasks instead of
                being set manually. Your manual value is kept and will start being used again
                if you remove all subtasks.
              </InfoHint>
            </span>
          </div>
          <ProgressField
            key={id}
            record={record}
            value={progress.value}
            disabled={!fields.progress}
            ariaLabel={progress.ariaLabel}
            onCommit={commit}
          />
          <p
            data-branch-note
            className={`text-xs text-zinc-400 dark:text-zinc-500 italic${progress.leaf ? " invisible" : ""}`}
          >
            Ignored — this task has subtasks.
          </p>
          <div
            data-computed-note
            className={`text-xs text-zinc-500 dark:text-zinc-400 italic${progress.leaf ? " invisible" : ""}`}
          >
            Computed from children: <span data-computed-readout>{progress.computed}</span>%
          </div>
        </div>
      </div>

      <SortMenu ctx={ctx} id={id} canEdit={canEdit} leaf={progress.leaf} />

      <div className="grid grid-cols-2 gap-3">
        <div>
          <label htmlFor="task-field-priority" className={LABEL}>
            <span className={canEdit ? "underline" : undefined}>P</span>riority
          </label>
          <select
            id="task-field-priority"
            name="task[priority]"
            className="w-full select select-bordered select-sm"
            disabled={!canEdit}
            value={record.priority}
            onChange={(e) => commit(priorityEdit(record, e.target.value))}
          >
            {PRIORITIES.map((p) => (
              <option key={p} value={p}>
                {p}
              </option>
            ))}
          </select>
        </div>
        <div>
          <label htmlFor="task-field-assignee" className={LABEL}>
            <span className={canEdit ? "underline" : undefined}>A</span>ssignee
          </label>
          {/* Option text is the bare username; the display name rides the
              option title. */}
          <select
            id="task-field-assignee"
            name="task[assignee_id]"
            className="w-full select select-bordered select-sm"
            disabled={!fields.assignee}
            value={record.assignee_id === null ? "" : String(record.assignee_id)}
            onChange={(e) => commit(assigneeEdit(record, e.target.value))}
          >
            <option value="">Unassigned</option>
            {assigneeOptions(ctx.members).map((user) => (
              <option key={user.id} value={user.id} title={user.name ?? undefined}>
                {user.username}
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Co-assignees (m02.05 item 13): ordered, manual — position is
          promotion order. The primary stays the assignee select above. */}
      {fields.coAssignees && (
        <div id="co-assignees">
          <span className={LABEL}>Co-assignees</span>
          <ul id={`co-list-${id}`} className="mt-1 space-y-1">
            {rows.map((row) => (
              <li
                key={row.id}
                id={`co-row-${row.id}`}
                data-co-row
                data-user-id={row.id}
                className="flex items-center gap-2 text-sm"
              >
                <CoAvatar user={row.user} online={ctx.presence.online.has(row.id)} />
                {/* Struck through when they have left (`member_user?/2`). The
                    client holds only current members, so a leaver has no name
                    here; say so rather than guess one. */}
                <span
                  className={`flex-1 min-w-0 truncate text-zinc-700 dark:text-zinc-200${
                    row.user === null ? " line-through" : ""
                  }`}
                >
                  {row.user === null ? "(no longer a member)" : `@${row.user.username}`}
                </span>
                {canEdit && (
                  <>
                    <button
                      type="button"
                      data-co-move
                      data-dir="up"
                      data-user-id={row.id}
                      disabled={row.first}
                      aria-label="Move up"
                      className={CO_MOVE}
                      onClick={() => commitCo(moveCoAssignee(record.co_assignee_ids, row.id, "up"))}
                    >
                      <Icon name="chevron-up" className="w-3.5 h-3.5" />
                    </button>
                    <button
                      type="button"
                      data-co-move
                      data-dir="down"
                      data-user-id={row.id}
                      disabled={row.last}
                      aria-label="Move down"
                      className={CO_MOVE}
                      onClick={() =>
                        commitCo(moveCoAssignee(record.co_assignee_ids, row.id, "down"))
                      }
                    >
                      <Icon name="chevron-down" className="w-3.5 h-3.5" />
                    </button>
                    <button
                      type="button"
                      data-co-remove
                      data-user-id={row.id}
                      aria-label={`Remove co-assignee ${
                        row.user === null ? "(no longer a member)" : `@${row.user.username}`
                      }`}
                      className="px-1 text-zinc-400 hover:text-red-600 dark:hover:text-red-400"
                      onClick={() => commitCo(removeCoAssignee(record.co_assignee_ids, row.id))}
                    >
                      <Icon name="x-mark" className="w-3.5 h-3.5" />
                    </button>
                  </>
                )}
              </li>
            ))}
            {rows.length === 0 && (
              <li data-co-empty className="text-xs text-zinc-400 dark:text-zinc-500 italic">
                None yet.
              </li>
            )}
          </ul>
          {canEdit && (
            <form id="add-co-assignee-form" className="mt-1" onSubmit={(e) => e.preventDefault()}>
              <select
                name="user_id"
                data-co-add
                className="w-full select select-bordered select-sm"
                value=""
                onChange={(e) => {
                  const userId = Number.parseInt(e.target.value, 10);
                  if (Number.isInteger(userId)) {
                    commitCo(addCoAssignee(record.co_assignee_ids, userId));
                  }
                }}
              >
                <option value="">+ Add co-assignee…</option>
                {coAssigneeOptions(record, ctx.members).map((user) => (
                  <option key={user.id} value={user.id} data-name={user.username}>
                    {user.username}
                  </option>
                ))}
              </select>
            </form>
          )}
        </div>
      )}

      <div className="flex items-center justify-between gap-2 border-t border-zinc-100 dark:border-zinc-700 pt-3">
        {/* "Last updated by …" needs `updated_by` / `updated_at`, which the tree
            read does not carry. The slot keeps its place so Delete sits where it
            does in the LiveView. */}
        <div className={LABEL} data-updated-slot />
        <div className="flex items-center gap-2">
          {canEdit && (
            <button
              id="delete-task-btn"
              type="button"
              className="inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-semibold text-white bg-red-600 hover:bg-red-700 dark:bg-red-700 dark:hover:bg-red-600"
              onClick={() => ctx.onIntent({ kind: "delete", id })}
            >
              <Icon name="trash" className="w-3.5 h-3.5" /> Delete
            </button>
          )}
        </div>
      </div>

      {/* Comments, Activity and chat go here. They are Arc 7 (`data-comments-block`,
          `data-activity-block` in `task_editor/1`) and are not drawn until then. */}
    </div>
  );
}

/**
 * "Link task" (m03.03 item 3.2). The %-reference picker itself is not ported
 * yet, so the button holds its place disabled rather than opening nothing.
 */
function RefPickerButton({ target }: { target: string }) {
  return (
    <button
      type="button"
      data-ref-picker={target}
      aria-label="Link a task by number"
      title="Link a task by number"
      disabled
      className="inline-flex items-center justify-center w-6 h-6 rounded text-zinc-400 hover:text-emerald-600 dark:hover:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30 active:scale-95 transition disabled:opacity-50 disabled:pointer-events-none"
    >
      <Icon name="link" className="w-4 h-4" />
    </button>
  );
}

interface FieldProps {
  record: TaskRecord;
  disabled: boolean;
  onCommit: (edit: EditableFields | null) => void;
}

/** Draft while focused, the record otherwise; commits on blur or Enter. */
function TitleField({ record, disabled, onCommit }: FieldProps) {
  const [draft, setDraft] = useState<string | null>(null);
  const shown = draft ?? record.title;

  const finish = (): void => {
    if (draft !== null) onCommit(titleEdit(record, draft));
    setDraft(null);
  };

  return (
    <input
      id="task-field-title"
      type="text"
      name="task[title]"
      value={shown}
      className="w-full input input-bordered input-sm"
      disabled={disabled}
      onFocus={() => setDraft(record.title)}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={finish}
      onKeyDown={(e: KeyboardEvent<HTMLInputElement>) => {
        if (e.key === "Enter") {
          e.preventDefault();
          e.currentTarget.blur();
        }
      }}
    />
  );
}

/** Same as the title, committing on blur only. */
function DescriptionField({ record, disabled, onCommit }: FieldProps) {
  const [draft, setDraft] = useState<string | null>(null);
  const shown = draft ?? record.description ?? "";

  return (
    <textarea
      id="task-field-description"
      name="task[description]"
      className="w-full textarea textarea-bordered textarea-sm"
      rows={3}
      disabled={disabled}
      value={shown}
      onFocus={() => setDraft(record.description ?? "")}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={() => {
        if (draft !== null) onCommit(descriptionEdit(record, draft));
        setDraft(null);
      }}
    />
  );
}

/**
 * The slider follows the thumb at once and commits 200ms after it stops —
 * the same debounce the LiveView field carries — so a drag is one write, not
 * twenty.
 */
function ProgressField({
  record,
  value,
  disabled,
  ariaLabel,
  onCommit,
}: FieldProps & { value: number; ariaLabel: string }) {
  const [draft, setDraft] = useState<number | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  useEffect(
    () => () => {
      if (timer.current !== null) clearTimeout(timer.current);
    },
    [],
  );

  return (
    <input
      id="task-field-progress"
      type="range"
      name="task[manual_progress]"
      min={0}
      max={100}
      step={5}
      value={draft ?? value}
      className="w-full"
      disabled={disabled}
      aria-label={ariaLabel}
      onChange={(e: ChangeEvent<HTMLInputElement>) => {
        const next = e.target.value;
        setDraft(Number.parseInt(next, 10));
        if (timer.current !== null) clearTimeout(timer.current);
        timer.current = setTimeout(() => {
          timer.current = null;
          onCommit(progressEdit(record, next));
          setDraft(null);
        }, 200);
      }}
    />
  );
}

/**
 * `sort_menu/1` with `scope="task"`: criterion dropdown + Reverse + "Make
 * descendants inherit". Invisible (not removed) on leaves so leaf↔branch
 * selection switches don't shift the layout below (§1.1).
 */
function SortMenu({
  ctx,
  id,
  canEdit,
  leaf,
}: {
  ctx: TreeContext;
  id: number;
  canEdit: boolean;
  leaf: boolean;
}) {
  const record = ctx.model.tasks[id];
  if (record === undefined) return null;
  const mode = record.sort_mode;
  const reverseOff = reverseDisabled(mode);

  const commit = (nextMode: typeof mode, reverse: boolean): void => {
    const edit = sortEdit(record, nextMode, reverse);
    if (edit !== null) ctx.onIntent({ kind: "setSort", id, mode: edit.mode, reverse: edit.reverse });
  };

  return (
    <div data-sort-block className={`space-y-1${leaf ? " invisible" : ""}`}>
      <label htmlFor="sort-mode-task" className={LABEL}>
        Sort children by
      </label>
      <form
        id="sort-form-task"
        data-task-id={id}
        className="flex items-center gap-2"
        onSubmit={(e) => e.preventDefault()}
      >
        <select
          id="sort-mode-task"
          name="mode"
          className="flex-1 select select-bordered select-sm"
          disabled={!canEdit}
          value={mode ?? ""}
          onChange={(e) => commit(sortModeFrom(e.target.value), record.sort_reverse)}
        >
          <option value="">{inheritLabel(ctx.model, id)}</option>
          {SORT_MODE_OPTIONS.map((m) => (
            <option key={m} value={m}>
              {sortModeLabel(m)}
            </option>
          ))}
        </select>
        <label
          htmlFor="sort-reverse-task"
          className={`flex items-center gap-1 text-xs select-none ${
            reverseOff ? "text-zinc-400 dark:text-zinc-500" : "text-zinc-600 dark:text-zinc-300"
          }`}
          title="Reverse the sort direction"
        >
          <input
            id="sort-reverse-task"
            type="checkbox"
            name="reverse"
            value="true"
            checked={record.sort_reverse}
            disabled={!canEdit || reverseOff}
            className="checkbox checkbox-xs"
            onChange={(e) => commit(mode, e.target.checked)}
          />{" "}
          Reverse
        </label>
      </form>
      {canEdit && (
        <button
          type="button"
          data-cascade-sort
          data-task-id={id}
          className="inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30 active:scale-95 transition"
          title="Force every descendant branch to inherit this branch's sort"
          onClick={() => ctx.onIntent({ kind: "cascadeSort", id })}
        >
          Make descendants inherit
        </button>
      )}
    </div>
  );
}

/**
 * `info_hint/1`: a native popover, placed next to its trigger on open the way
 * the LiveView's Popover hook places it, and clamped to the viewport.
 */
function InfoHint({
  id,
  label,
  children,
}: {
  id: string;
  label: string;
  children: ReactNode;
}) {
  const popId = `${id}-pop`;
  const place = (e: ToggleEvent<HTMLDivElement>): void => {
    if (e.newState !== "open") return;
    const panel = e.currentTarget;
    const button = document.querySelector<HTMLElement>(`[popovertarget='${popId}']`);
    if (button === null) return;
    const r = button.getBoundingClientRect();
    const width = Math.min(panel.offsetWidth || 256, window.innerWidth - 16);
    const left = Math.min(Math.max(8, r.left), window.innerWidth - width - 8);
    let top = r.bottom + 6;
    const height = panel.offsetHeight;
    if (top + height > window.innerHeight - 8) top = Math.max(8, r.top - height - 6);
    Object.assign(panel.style, { position: "fixed", left: `${left}px`, top: `${top}px`, margin: "0" });
  };

  return (
    <span className="inline-flex items-center">
      <button
        type="button"
        aria-label={label}
        popoverTarget={popId}
        className="text-zinc-400 hover:text-zinc-600 dark:hover:text-zinc-200"
      >
        <Icon name="information-circle" className="w-4 h-4" />
      </button>
      <div
        id={popId}
        popover="auto"
        role="tooltip"
        onToggle={place}
        className="w-64 rounded-md border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-3 text-xs font-normal not-italic text-zinc-600 dark:text-zinc-300 shadow-lg"
      >
        {children}
      </div>
    </span>
  );
}

/** The co-assignee list's disc, lit when they are online (`avatar/1`). */
function CoAvatar({ user, online }: { user: RowUser | null; online: boolean }) {
  return (
    <span
      data-pill-avatar
      aria-hidden="true"
      className={`avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-5 h-5 text-[10px]${
        online ? " chip-online" : ""
      }`}
      style={user === null ? undefined : avatarStyle(user)}
      title={user === null ? undefined : (user.name ?? user.username)}
    >
      {user === null ? "?" : initials(user)}
    </span>
  );
}
