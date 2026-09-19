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
import { memo, useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";

import { Icon } from "../ui/icon.tsx";
import { afterPaint } from "./after_paint.ts";
import { BotanicalIcon, Chevron } from "./botanical.tsx";
import { UnitBadge } from "./unit_badge.tsx";
import { inField } from "./use_tree_keyboard.ts";
import type { RefPart, RowUser } from "./row_model.ts";
import {
  REF_DEAD_CLASS,
  REF_LINK_CLASS,
  assigneeView,
  avatarStyle,
  badgeTitle,
  botanicalColor,
  botanicalKindOf,
  initials,
} from "./row_model.ts";
import type { Selection } from "../live/presence_model.ts";
import type { TreeContext } from "./context.ts";
import { clickedSelection } from "./selection_model.ts";
import { useLabel, useRow } from "./use_task_store.ts";
import type { TaskReader } from "./task_store.ts";

const NO_BADGES: readonly Selection[] = [];

export interface RowProps {
  ctx: TreeContext;
  id: number;
  depth: number;
  /** The rows nested under this one. Built by `tree.tsx`, not by the row. */
  children?: ReactNode;
}

/**
 * Prose with its `%<id>` references resolved to live labels. A live reference
 * is a link to its task: the click reveals it (the workspace's `a.doit-ref`
 * listener) and never selects the row it sits in.
 */
function Prose({ parts, onReveal }: { parts: readonly RefPart[]; onReveal: (id: number) => void }) {
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
          <a
            key={index}
            className={REF_LINK_CLASS}
            data-task-id={part.id}
            role="link"
            onClick={(event) => {
              event.preventDefault();
              event.stopPropagation();
              onReveal(part.id);
            }}
          >
            {part.label}
          </a>
        );
      })}
    </>
  );
}

function CopyIndexButton({ label }: { label: string }) {
  const [copied, setCopied] = useState(false);
  // The tick clears itself after a beat. If the row goes away first — a delete,
  // a collapse, a route change — the timer has to go with it.
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(
    () => () => {
      if (timer.current !== null) clearTimeout(timer.current);
    },
    [],
  );

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
            if (timer.current !== null) clearTimeout(timer.current);
            timer.current = setTimeout(() => setCopied(false), 1200);
          })
          .catch(() => undefined);
      }}
      className="flex-none inline-flex items-center justify-center w-4 h-4 rounded text-zinc-400 hover:text-zinc-700 dark:text-zinc-500 dark:hover:text-zinc-200 opacity-0 group-hover/row:opacity-100 focus-visible:opacity-100 [@media(hover:none)]:opacity-100 transition-opacity motion-reduce:transition-none"
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
      {/* No online dot here: the LiveView lights the primary assignee's disc only. */}
    </span>
  );
}

/**
 * The number label ("3.2.1"), reading its index for itself (7.21): a move
 * that renumbers the tree re-renders these — a few elements each — and not
 * the rows. Empty under the "none" style = no element.
 */
const IndexLabel = memo(function IndexLabel({ tasks, id }: { tasks: TaskReader; id: number }) {
  const label = useLabel(tasks, id);
  if (label === "") return null;
  return (
    <span
      data-task-index
      className="group/idx flex-none inline-flex items-center gap-1 font-mono text-xs font-medium text-zinc-500 dark:text-zinc-400 tabular-nums select-none"
    >
      {label}
      <CopyIndexButton label={label} />
    </span>
  );
});

export function Row({ ctx, id, depth, children }: RowProps) {
  const [addMenuOpen, setAddMenuOpen] = useState(false);
  // This row's own view of the model (7.18): the same object back until
  // something this row paints has changed, so a write elsewhere in the tree
  // costs this row nothing.
  const view = useRow(ctx.tasks, id);
  // This row's own subscription: a selection change re-renders the two rows
  // it concerns, not every row under a context that changed identity.
  const selected = useSyncExternalStore(
    ctx.selection.subscribe,
    () => ctx.selection.get() === id,
    () => false,
  );
  // Likewise the branch's own open state (7.9.1): a toggle re-renders this
  // row and its children list, not every row.
  const expanded = useSyncExternalStore(
    ctx.collapse.subscribe,
    () => !ctx.collapse.get(id),
    () => true,
  );
  // And presence (7.17): this row's badges, and the dot on its assignee's
  // disc — the CSS keys off `[data-pill-avatar].chip-online`, which the
  // co-assignee discs do not carry. The store hands back the same badges
  // until they change, so another member moving elsewhere costs this row
  // nothing, and this window's own selection echoing back costs no row at all.
  const assigneeId = view?.record.assignee_id ?? null;
  const badges = useSyncExternalStore(
    ctx.presence.subscribe,
    () => ctx.presence.badges(id),
    () => NO_BADGES,
  );
  const online = useSyncExternalStore(
    ctx.presence.subscribe,
    () => ctx.presence.online(assigneeId),
    () => false,
  );

  // The roving tabindex (7.12.1): the selected row is the one Tab reaches;
  // with nothing selected, the first row is. Every other row is -1. Only the
  // rows whose answer changes re-render. Both stores are watched: which row
  // is first is the model's answer, and a reorder must move the tab stop.
  const subscribeTabStop = useCallback(
    (listener: () => void) => {
      const offSelection = ctx.selection.subscribe(listener);
      const offTasks = ctx.tasks.subscribe(listener);
      return () => {
        offSelection();
        offTasks();
      };
    },
    [ctx.selection, ctx.tasks],
  );
  const tabIndex = useSyncExternalStore(
    subscribeTabStop,
    () => {
      const current = ctx.selection.get();
      if (current === id) return 0;
      return current === null && depth === 0 && ctx.tasks.children(ctx.tasks.rootId()).ids[0] === id ? 0 : -1;
    },
    () => -1,
  );
  // The selection is also the focus a screen reader follows — unless the user
  // is typing somewhere (the add form, the pane, a title editor), which a
  // selection change must never pull them out of.
  const li = useRef<HTMLLIElement | null>(null);
  useEffect(() => {
    if (!selected) return;
    const active = document.activeElement;
    if (active !== null && active !== document.body) {
      if (inField(active) || active.closest("#details-rail, #add-task-form, #initiative-header") !== null) return;
    }
    li.current?.focus({ preventScroll: true });
  }, [selected]);

  if (view === null) return null;
  const { record, branch, progress } = view;
  const kind = botanicalKindOf(branch, depth);
  const done = record.status === "done";
  const canProgress = ctx.canProgress(id);
  const assignee = assigneeView(record, ctx.members);
  const display = ctx.rows;

  return (
    <li
      ref={li}
      id={`task-${id}`}
      role="treeitem"
      aria-level={depth + 1}
      aria-selected={selected}
      {...(branch ? { "aria-expanded": expanded } : {})}
      tabIndex={tabIndex}
      data-task-id={id}
      data-depth={depth}
      data-sort={record.sort_mode ?? ""}
      data-sort-reverse={String(record.sort_reverse)}
      {...(selected ? { "data-selected": "" } : {})}
      className="rounded border border-zinc-400 dark:border-zinc-700 bg-white dark:bg-zinc-900 first:border-t-2 first:border-t-zinc-500 dark:first:border-t-zinc-500 focus:outline-none focus-visible:ring-2 focus-visible:ring-emerald-500"
    >
      {/* `data-done` drives the done styling — one attribute, so the optimistic
          toggle in the next task flips one thing rather than juggling classes. */}
      <div
        data-task-row
        {...(done ? { "data-done": "true" } : {})}
        data-task-progress={progress}
        data-can-progress={String(canProgress)}
        onClick={() => ctx.onSelect(clickedSelection(selected ? id : null, id))}
        className={[
          "group/row relative flex flex-wrap items-center gap-x-2 xl:gap-x-3 gap-y-1 px-3 xl:px-5 2xl:px-6 pt-2 pb-6 min-w-[240px] cursor-pointer",
          view.saving ? "is-saving" : "",
          view.recomputing ? "is-recomputing" : "",
          "hover:bg-zinc-50 dark:hover:bg-zinc-800/50",
        ]
          .filter((part) => part !== "")
          .join(" ")}
      >
        {ctx.permissions.canEdit ? (
          // The drag handle, same anatomy as the LiveView's. The gesture is
          // bound by `drag.tsx` on the tree, not here, so the row stays markup.
          <span
            data-drag-handle
            aria-hidden="true"
            data-task-id={id}
            data-parent-id={record.parent_id}
            data-depth={depth}
            className="flex-none -my-2 w-11 h-11 flex items-center justify-center gap-0.5 text-zinc-600 dark:text-zinc-600 hover:text-zinc-800 dark:hover:text-zinc-400 cursor-grab active:cursor-grabbing touch-none"
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

        {/* The unit-count badge, on the pill line between the handle and the
            index label (7.8.6): with the chevron on the border line, nothing
            but the title is left on the title line's edge. A tiny "s" after
            the icon says plural when the count is not 1 (7.8.7). */}
        {view.units !== null && display.count && (
          <UnitBadge
            calc={view.calc}
            total={view.units.total}
            // A top-level branch stacks its completed count above the total.
            {...(depth === 0 ? { done: view.units.done } : {})}
            className="flex-none group-data-done/row:text-emerald-500"
          />
        )}

        {/* The positional label, on its own subscription (7.21). */}
        <IndexLabel tasks={ctx.tasks} id={id} />

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
                className={[
                  "avatar-emboss relative inline-flex flex-none items-center justify-center w-3.5 h-3.5 mr-1 rounded-full text-[8px] font-semibold select-none",
                  online ? "chip-online" : "",
                ]
                  .filter((part) => part !== "")
                  .join(" ")}
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

          {/* Other members' selection-presence avatars (item 3.4.2): the same
              disc `applyPresenceBadges` builds, from the store instead of the
              DOM. Ready-made colours — the meta carries them, so no lookup. */}
          <span
            data-presence-slot={id}
            className="inline-flex items-center gap-0.5 flex-none"
            aria-hidden="true"
          >
            {badges.map((badge) => (
              <span
                key={badge.user_id}
                className="avatar-emboss inline-flex flex-none items-center justify-center w-4 h-4 rounded-full text-[8px] font-semibold select-none"
                style={{ backgroundImage: badge.bg, color: badge.fg }}
                title={badgeTitle(badge)}
              >
                {badge.initials}
              </span>
            ))}
          </span>
        </div>

        {/* Row 1, pinned right: the new-task control. */}
        {ctx.permissions.canEdit && (
          <div className="relative flex-none ml-auto">
            <div
              data-add-group
              className="inline-flex rounded border border-emerald-600 dark:border-emerald-500 overflow-hidden"
            >
              <button
                type="button"
                data-add-child={id}
                onClick={(event) => {
                  event.stopPropagation();
                  setAddMenuOpen(false);
                  ctx.onOpenAdd({ kind: "child", taskId: id });
                }}
                className="inline-flex items-center justify-center gap-1 w-8 h-8 sm:w-auto sm:h-auto sm:min-w-11 sm:min-h-6 sm:px-2 sm:py-0.5 text-xs font-bold text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
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
          {/* The chevron hangs off a zero-width, full-height item of its own
              (never row 2 itself: the completion box below is positioned
              against the row) and app.css moves it onto the parent's left
              border line (7.8.1); -mr-1 cancels the gap the empty item earns. */}
          {branch && (
            <span className="relative flex-none w-0 -mr-1 self-stretch">
            <button
              type="button"
              id={`collapse-${id}`}
              aria-controls={`children-${id}`}
              aria-expanded={expanded}
              aria-label="Toggle children"
              onClick={(event) => {
                event.stopPropagation();
                // The glyph flips in this very task (7.8.8); the collapse —
                // a whole-tree render today, item 7.9 — follows once the
                // browser has painted it. React re-applies the same value
                // when the state catches up, so nothing fights over it.
                event.currentTarget.setAttribute("aria-expanded", String(!expanded));
                afterPaint(() => ctx.onToggleCollapse(id));
              }}
              className="group flex-none inline-flex items-center justify-center w-6 h-6 rounded-full dark:border-2 dark:border-black text-black bg-emerald-400 hover:bg-emerald-300 group-data-done/row:bg-emerald-500 group-data-done/row:hover:bg-emerald-400 drop-shadow-[0_1px_1px_rgb(0,0,0)] dark:drop-shadow-none transition-colors motion-reduce:transition-none"
            >
              <Chevron />
            </button>
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
                "group/check absolute bottom-0.5 left-3 z-10 w-6 h-6 rounded border-2 flex items-center justify-center transition-colors motion-reduce:transition-none",
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
            <Prose parts={view.title} onReveal={ctx.onReveal} />
          </span>
        </div>

        {/* Row 3: the description, always in the DOM so an echo can fill it. */}
        <span
          data-task-description
          hidden={record.description === null || record.description === ""}
          className="w-full min-w-0 text-sm text-zinc-400 dark:text-zinc-500 truncate xl:whitespace-normal xl:line-clamp-2"
        >
          {view.description === null ? null : <Prose parts={view.description} onReveal={ctx.onReveal} />}
        </span>

        {display.progress && (
          <div
            className={[
              "absolute bottom-1 right-2 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden",
              ctx.permissions.canEdit ? "left-10" : "left-2",
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
