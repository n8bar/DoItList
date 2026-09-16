// One task row (m04.02 items 2.1.1–2.1.4).
//
// A port of `task_node/1` (initiative_workspace_live.ex ~5708): the same `li` /
// `[data-task-row]` shell, the same attributes, the same class lists — because
// `assets/css/app.css` is shared, and every rule it carries for the tree
// (`li[data-selected]`, `ul.collapsed-peek`, the priority chip's colours, the
// progress text) keys off exactly these names. A near-enough copy would render
// an unstyled tree.
//
// The decisions are all in `row_model.ts`; this file is markup. What it does
// own is the shape of the DOM, so the two rules the row must never break are
// written here: the title is never truncated (ProductSpec §6.2 — it wraps), and
// nothing a user does to a row waits on the network.

import type { ReactNode } from "react";
import { useState } from "react";

import { Icon } from "../ui/icon.tsx";
import { childIdsOf } from "./model.ts";
import { doneUnitCount, unitCount } from "./progress.ts";
import { BotanicalIcon, Chevron } from "./botanical.tsx";
import type { RefPart, RowUser } from "./row_model.ts";
import {
  REF_DEAD_CLASS,
  REF_LINK_CLASS,
  assigneeView,
  avatarStyle,
  badgeIcon,
  badgeIconClass,
  botanicalColor,
  botanicalKind,
  branchUnitTitle,
  initials,
  progressValue,
  refParts,
} from "./row_model.ts";
import type { TreeContext } from "./context.ts";

export interface RowProps {
  ctx: TreeContext;
  id: number;
  depth: number;
  /** The rows nested under this one. Built by `tree.tsx`, not by the row. */
  children?: ReactNode;
}

/** Prose with its `%<id>` references resolved to live labels. */
function Prose({ parts }: { parts: readonly RefPart[] }) {
  if (parts.length === 1 && parts[0]?.kind === "text") return <>{parts[0].text}</>;
  return (
    <>
      {parts.map((part, index) => {
        if (part.kind === "text") return <span key={index}>{part.text}</span>;
        if (part.kind === "dead") {
          return (
            <span
              key={index}
              className={REF_DEAD_CLASS}
              data-task-id={part.id}
              title="Referenced task not found"
            >
              %?
            </span>
          );
        }
        return (
          <a key={index} className={REF_LINK_CLASS} data-task-id={part.id} role="link">
            {part.label}
          </a>
        );
      })}
    </>
  );
}

function CopyIndexButton({ label }: { label: string }) {
  const [copied, setCopied] = useState(false);

  return (
    <button
      type="button"
      data-copy-index={label}
      aria-label={`Copy index ${label}`}
      title="Copy index"
      onClick={(event) => {
        event.stopPropagation();
        // Client-only, and acknowledged at the click: the tick shows whether
        // the clipboard took it, never a spinner (§6.7).
        void navigator.clipboard
          ?.writeText(label)
          .then(() => {
            setCopied(true);
            setTimeout(() => setCopied(false), 1200);
          })
          .catch(() => undefined);
      }}
      className="flex-none inline-flex items-center justify-center w-4 h-4 rounded text-zinc-400 hover:text-zinc-700 dark:text-zinc-500 dark:hover:text-zinc-200 opacity-0 group-hover/row:opacity-100 focus-visible:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity"
    >
      {copied ? (
        <span data-copied-icon className="inline-flex text-emerald-600 dark:text-emerald-400">
          <Icon name="check" className="w-3 h-3" />
        </span>
      ) : (
        <span data-copy-icon className="inline-flex">
          <Icon name="clipboard-document" className="w-3 h-3" />
        </span>
      )}
    </button>
  );
}

function Avatar({ user, className }: { user: RowUser; className: string }) {
  return (
    <span
      className={`avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none ${className}`}
      style={avatarStyle(user)}
      title={user.name ?? user.username}
      aria-hidden="true"
    >
      {initials(user)}
      {/* The online dot's slot. Presence fills it in item 2.4.2. */}
    </span>
  );
}

export function Row({ ctx, id, depth, children }: RowProps) {
  const [addMenuOpen, setAddMenuOpen] = useState(false);

  const record = ctx.model.tasks[id];
  if (record === undefined) return null;

  const childIds = childIdsOf(ctx.model, id);
  const branch = childIds.length > 0;
  const kind = botanicalKind(ctx.model, id, depth);
  const done = record.status === "done";
  const progress = progressValue(ctx.model, id);
  const canProgress = ctx.canProgress(id);
  const expanded = !ctx.collapsed(id);
  const assignee = assigneeView(record, ctx.members);
  const selected = ctx.selectedTaskId === id;
  const display = ctx.rows;

  return (
    <li
      id={`task-${id}`}
      data-task-id={id}
      data-depth={depth}
      data-sort={record.sort_mode ?? ""}
      data-sort-reverse={String(record.sort_reverse)}
      {...(selected ? { "data-selected": "" } : {})}
      className="rounded border border-zinc-400 dark:border-zinc-700 bg-white dark:bg-zinc-900 first:border-t-2 first:border-t-zinc-500 dark:first:border-t-zinc-500"
    >
      {/* `data-done` drives the done styling — one attribute, so the optimistic
          toggle in the next task flips one thing rather than juggling classes. */}
      <div
        data-task-row
        {...(done ? { "data-done": "true" } : {})}
        data-task-progress={progress}
        data-can-progress={String(canProgress)}
        onClick={() => ctx.onSelect(id)}
        className={[
          "group/row relative flex flex-wrap items-center gap-x-2 xl:gap-x-3 gap-y-1 px-3 xl:px-5 2xl:px-6 pt-2 pb-6 min-w-[240px] cursor-pointer",
          ctx.savingIds.has(id) ? "is-saving" : "",
          ctx.recomputingIds.has(id) ? "is-recomputing" : "",
          "hover:bg-zinc-50 dark:hover:bg-zinc-800/50",
        ]
          .filter((part) => part !== "")
          .join(" ")}
      >
        {ctx.permissions.canEdit ? (
          // The drag handle's geometry, held open so the row's anatomy matches
          // the LiveView's. The gesture itself is item 2.3; until it lands the
          // handle deliberately does NOT claim a grab cursor it cannot honour.
          <span
            data-drag-handle
            aria-hidden="true"
            data-task-id={id}
            data-parent-id={record.parent_id}
            data-depth={depth}
            className="flex-none -my-2 w-11 h-11 flex items-center justify-center gap-0.5 text-zinc-600 dark:text-zinc-600 touch-none"
          >
            <Icon name="ellipsis-vertical" className="w-3 h-3" />
            <span className={botanicalColor(kind)}>
              <BotanicalIcon kind={kind} />
            </span>
            <Icon name="ellipsis-vertical" className="w-3 h-3" />
          </span>
        ) : (
          <span className={`flex-none ${botanicalColor(kind)}`} aria-hidden="true">
            <BotanicalIcon kind={kind} />
          </span>
        )}

        {/* The positional label. Empty under the "none" style = no element. */}
        {record.index !== "" && (
          <span
            data-task-index
            className="group/idx flex-none inline-flex items-center gap-1 font-mono text-xs font-medium text-zinc-500 dark:text-zinc-400 tabular-nums select-none"
          >
            {record.index}
            <CopyIndexButton label={record.index} />
          </span>
        )}

        {/* Row 1: the attribute chips, clipping together rather than wrapping. */}
        <div className="flex flex-1 items-center gap-2 min-w-0 overflow-hidden">
          <span
            className="task-id-pill items-center justify-center h-5 px-1.5 rounded-full text-xs flex-none font-mono bg-amber-100 text-amber-800 dark:bg-amber-900/40 dark:text-amber-300"
            title={`parent ${record.parent_id}`}
          >
            {`#${id}`}
          </span>

          {display.priority && (
            <button
              type="button"
              onClick={(event) => {
                event.stopPropagation();
                ctx.onSelect(id);
              }}
              data-pill="priority"
              data-pill-set
              data-priority={record.priority}
              className="priority-pill inline-flex items-center justify-center h-5 min-w-9 px-1.5 rounded-full text-xs flex-none cursor-pointer border"
              title={`Priority: ${record.priority}`}
            >
              {record.priority}
            </button>
          )}

          {display.assignee && (
            <button
              type="button"
              onClick={(event) => {
                event.stopPropagation();
                ctx.onSelect(id);
              }}
              data-pill="assignee"
              {...(assignee.set ? { "data-pill-set": "" } : {})}
              className={[
                "inline-flex items-center justify-center h-5 min-w-9 max-w-[45%] px-1.5 rounded-full text-xs flex-none cursor-pointer",
                "border border-dashed border-zinc-300 dark:border-zinc-600",
                "data-pill-set:border-solid data-pill-set:border-zinc-400 dark:data-pill-set:border-zinc-500 data-pill-set:bg-zinc-100 dark:data-pill-set:bg-zinc-800 data-pill-set:text-zinc-600 dark:data-pill-set:text-zinc-300",
              ].join(" ")}
              title={assignee.title}
            >
              <span
                data-pill-avatar
                data-assignee-id={record.assignee_id ?? undefined}
                hidden={assignee.user === null}
                className="avatar-emboss relative inline-flex flex-none items-center justify-center w-3.5 h-3.5 mr-1 rounded-full text-[8px] font-semibold select-none"
                style={assignee.user === null ? undefined : avatarStyle(assignee.user)}
                aria-hidden="true"
              >
                {assignee.user === null ? null : initials(assignee.user)}
              </span>
              {/* Struck through when the assignee has left: they keep their
                  assignments, and the strike says so at a glance. */}
              <span
                className={`truncate${assignee.exMember ? " line-through" : ""}`}
                data-pill-text
              >
                {assignee.user === null ? "" : `@${assignee.user.username}`}
              </span>
              {assignee.coCount > 0 && (
                <span
                  data-co-count
                  title={`${assignee.coCount} co-assignee(s)`}
                  className="ml-0.5 flex-none inline-flex items-center"
                >
                  <span className="text-[10px] font-semibold opacity-80">+</span>
                  <span className="inline-flex items-center -space-x-1 ml-0.5">
                    {assignee.coUsers.map((user) => (
                      <Avatar
                        key={user.id}
                        user={user}
                        className="w-3.5 h-3.5 text-[7px] ring-1 ring-white dark:ring-zinc-900"
                      />
                    ))}
                  </span>
                  {assignee.coOverflow > 0 && (
                    <span className="ml-0.5 text-[10px] font-semibold opacity-80">
                      +{assignee.coOverflow}
                    </span>
                  )}
                </span>
              )}
            </button>
          )}

          {/* Other members' selection-presence avatars land here (item 2.4.2). */}
          <span
            data-presence-slot={id}
            className="inline-flex items-center gap-0.5 flex-none"
            aria-hidden="true"
          />
        </div>

        {/* Row 1, pinned right: the new-task control. */}
        {ctx.permissions.canEdit && (
          <div className="relative flex-none ml-auto">
            <div className="inline-flex rounded border border-emerald-600 dark:border-emerald-500 overflow-hidden">
              <button
                type="button"
                data-add-child={id}
                onClick={(event) => {
                  event.stopPropagation();
                  setAddMenuOpen(false);
                  ctx.onOpenAdd({ kind: "child", taskId: id });
                }}
                className="inline-flex items-center justify-center gap-1 w-8 h-8 sm:w-auto sm:h-auto sm:min-w-11 sm:px-2 sm:py-0.5 text-xs font-bold text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
                aria-label={depth === 0 ? "New task" : "New subtask"}
                title={depth === 0 ? "New task" : "New subtask"}
              >
                <Icon name="plus" className="w-4 h-4" />
                <span className="hidden sm:inline">
                  <span className="kbd-key">N</span>
                  {depth === 0 ? "ew Task" : "ew Subtask"}
                </span>
              </button>
              <button
                type="button"
                id={`add-menu-${id}`}
                aria-expanded={addMenuOpen}
                onClick={(event) => {
                  event.stopPropagation();
                  setAddMenuOpen((open) => !open);
                }}
                aria-label="More add options"
                title="More add options"
                className="hidden sm:inline-flex items-center px-1 text-emerald-700 dark:text-emerald-400 border-l border-emerald-600 dark:border-emerald-500 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
              >
                <Icon name="chevron-down" className="w-3.5 h-3.5" />
              </button>
            </div>
            {addMenuOpen && (
              <div
                id={`add-menu-panel-${id}`}
                className="absolute right-0 top-full mt-1 z-10 bg-white dark:bg-zinc-900 border border-zinc-300 dark:border-zinc-700 rounded shadow-lg"
              >
                <button
                  type="button"
                  data-add-sibling={id}
                  onClick={(event) => {
                    event.stopPropagation();
                    setAddMenuOpen(false);
                    ctx.onOpenAdd({ kind: "sibling", taskId: id });
                  }}
                  className="block w-full text-left whitespace-nowrap px-3 py-1.5 text-xs text-zinc-700 dark:text-zinc-200 hover:bg-zinc-100 dark:hover:bg-zinc-800"
                >
                  + Add <span className="kbd-key">S</span>ibling
                </button>
              </div>
            )}
          </div>
        )}

        {/* Row 2: the title with its glued chevron. */}
        <div className="w-full flex items-baseline gap-1 min-w-0">
          {branch && (
            <button
              type="button"
              id={`collapse-${id}`}
              aria-controls={`children-${id}`}
              aria-expanded={expanded}
              aria-label="Toggle children"
              onClick={(event) => {
                event.stopPropagation();
                ctx.onToggleCollapse(id);
              }}
              className="group flex-none inline-flex items-center justify-center w-5 h-5 rounded-full dark:border-2 dark:border-black text-black bg-emerald-400 hover:bg-emerald-300 group-data-done/row:bg-emerald-500 group-data-done/row:hover:bg-emerald-400 drop-shadow-[0_1px_1px_rgb(0,0,0)] dark:drop-shadow-none transition-colors motion-reduce:transition-none"
            >
              <Chevron />
            </button>
          )}

          {branch && display.count && (
            <span
              title={branchUnitTitle(ctx.progressCalc)}
              className="flex-none relative top-[-0.4em] inline-flex items-center gap-0.5 text-sm font-bold tabular-nums text-emerald-400 group-data-done/row:text-emerald-500"
            >
              <BotanicalIcon
                kind={badgeIcon(ctx.progressCalc)}
                className={badgeIconClass(ctx.progressCalc)}
              />
              {depth === 0 ? (
                <BranchCount
                  done={doneUnitCount(ctx.model, id)}
                  total={unitCount(ctx.model, id)}
                />
              ) : (
                unitCount(ctx.model, id)
              )}
            </span>
          )}

          {canProgress && display.progress && (
            <button
              type="button"
              data-complete-toggle
              aria-label={done ? "Reopen task" : "Mark task completed"}
              aria-pressed={done}
              onClick={(event) => {
                event.stopPropagation();
                ctx.onIntent({ kind: branch ? "cascadeComplete" : "toggleComplete", id, done: !done });
              }}
              className={[
                "group/check absolute bottom-0.5 left-3 z-10 w-5 h-5 rounded border-2 flex items-center justify-center transition-colors motion-reduce:transition-none",
                "border-emerald-500 bg-transparent text-emerald-500 hover:border-emerald-400",
                "drop-shadow-[0_1px_1px_rgba(0,0,0,0.65)]",
                "dark:[filter:drop-shadow(0_1px_1px_rgb(0,0,0))_drop-shadow(0_1px_1px_rgb(0,0,0))_drop-shadow(0_1px_1px_rgb(0,0,0))_drop-shadow(0_1px_1px_rgb(0,0,0))_drop-shadow(0_1px_1px_rgb(0,0,0))]",
              ].join(" ")}
            >
              <Icon
                name="check-micro"
                className="w-5 h-5 [mask-size:100%_100%] [-webkit-mask-size:100%_100%] hidden group-aria-pressed/check:inline-block"
              />
            </button>
          )}

          {/* Never truncated: a title wraps (ProductSpec §6.2). */}
          <span
            data-task-title
            className={[
              "flex-1 min-w-0",
              depth === 0 ? "text-xl 2xl:text-2xl font-bold" : "text-sm font-medium",
              "group-data-done/row:line-through group-data-done/row:text-zinc-400 dark:group-data-done/row:text-zinc-500",
            ].join(" ")}
          >
            <Prose parts={refParts(record.title, ctx.model)} />
          </span>
        </div>

        {/* Row 3: the description, always in the DOM so an echo can fill it. */}
        <span
          data-task-description
          hidden={record.description === null || record.description === ""}
          className="w-full min-w-0 text-sm text-zinc-400 dark:text-zinc-500 truncate xl:whitespace-normal xl:line-clamp-2"
        >
          {record.description === null || record.description === "" ? null : (
            <Prose parts={refParts(record.description, ctx.model)} />
          )}
        </span>

        {display.progress && (
          <div
            className={[
              "absolute bottom-1 right-2 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden",
              ctx.permissions.canEdit ? "left-9" : "left-2",
            ].join(" ")}
            role="progressbar"
            aria-valuenow={progress}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-label={`Progress: ${progress}%`}
            style={{ ["--progress" as string]: `${progress}%` }}
          >
            <div
              className="absolute inset-y-0 left-0 rounded-full bg-emerald-400 group-data-done/row:bg-emerald-500"
              style={{ width: "var(--progress)" }}
            />
            <span className="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
              {progress}%
            </span>
          </div>
        )}
      </div>

      {children}
    </li>
  );
}

/** A top-level branch stacks its completed count above the total, faded. */
function BranchCount({ done, total }: { done: number; total: number }) {
  return (
    <span className="inline-flex flex-col items-center leading-none">
      {done > 0 && done < total && (
        <span data-done-count className="text-[0.7em] opacity-50">
          {done}
        </span>
      )}
      <span>{total}</span>
    </span>
  );
}
