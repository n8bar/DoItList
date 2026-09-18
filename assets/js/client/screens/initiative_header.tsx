// The Initiative header (m04.02 item 7.10): the workspace's `initiative_header/1`
// — grove icon + name as a click-to-edit wrapper for editors, the unit-count
// badge beside it, the subtitle line, the roll-up bar, and New List at the
// title row's right from `lg:` up. Same structure, controls and copy. The one
// thing the workspace does elsewhere is the edit itself (its rail pane); here
// the name and the subtitle edit in place, and the write is predicted (§6).

import type { CSSProperties, KeyboardEvent } from "react";
import { useState } from "react";

import type { ProgressCalc } from "../api/types.ts";
import { reservedHeight } from "../frame/layout_budget.ts";
import { BotanicalIcon } from "../tree/botanical.tsx";
import { UnitBadge } from "../tree/unit_badge.tsx";
import { Icon } from "../ui/icon.tsx";
import { Heading } from "./chrome.tsx";
import type { HeaderCounts, HeaderFields } from "./initiative_header_model.ts";
import {
  EDIT_NAME_LABEL,
  EDIT_NAME_TITLE,
  EDIT_SUBTITLE_TITLE,
} from "./initiative_header_model.ts";

export interface InitiativeHeaderProps {
  name: string;
  subtitle: string | null;
  progress: number;
  /** The badge's numbers; `null` before there is a tree to count. */
  counts: HeaderCounts | null;
  calc: ProgressCalc | null;
  canEdit: boolean;
  /** Skeleton lines instead of the subtitle and the bar. */
  loading: boolean;
  onAddRoot?: () => void;
  onCommit?: (fields: HeaderFields) => void;
}

type Editing = "name" | "subtitle" | null;

const TITLE_CLASS =
  "text-2xl font-semibold text-zinc-800 dark:text-zinc-100 group-hover:text-zinc-900 dark:group-hover:text-white";

export function InitiativeHeader({
  name,
  subtitle,
  progress,
  counts,
  calc,
  canEdit,
  loading,
  onAddRoot,
  onCommit,
}: InitiativeHeaderProps) {
  const [editing, setEditing] = useState<Editing>(null);
  const editable = canEdit && onCommit !== undefined;

  const commit = (fields: HeaderFields): void => {
    setEditing(null);
    onCommit?.(fields);
  };

  const title =
    editing === "name" ? (
      <Heading className={TITLE_CLASS}>
        <InlineField
          id="initiative-name-field"
          label={EDIT_NAME_LABEL}
          value={name}
          className="text-2xl font-semibold text-zinc-800 dark:text-zinc-100"
          onCommit={(value) => commit({ name: value })}
          onCancel={() => setEditing(null)}
        />
      </Heading>
    ) : (
      <Heading className={TITLE_CLASS}>{name}</Heading>
    );

  return (
    <div
      id="initiative-header"
      className="relative pb-6"
      style={{ minHeight: reservedHeight("initiative-header") }}
    >
      {/* Title row (dedicated): grove icon + name. New List inline on desktop only. */}
      <div className="flex items-start gap-2">
        {editable ? (
          // The grove icon + title are one click/tap-to-edit signifier, styled
          // as a subtle button (persistent soft border, hover tint, pressed
          // state). An <h1> can't live in a real <button>, so this is a
          // role="button" wrapper with keyboard support. While the name is
          // being edited it stays pressed, as the workspace's does with its
          // editor open.
          <span
            data-edit-initiative
            data-keep="editor-signifier"
            role="button"
            tabIndex={0}
            aria-label={EDIT_NAME_LABEL}
            title={EDIT_NAME_TITLE}
            className={[
              "group flex items-start gap-2 px-2 py-1 rounded-lg cursor-pointer border border-zinc-400 dark:border-zinc-500 hover:bg-zinc-100 dark:hover:bg-zinc-800 active:bg-zinc-200 dark:active:bg-zinc-700 transition",
              editing === "name" ? "editor-open" : "",
            ]
              .filter((part) => part !== "")
              .join(" ")}
            onClick={() => {
              if (editing !== "name") setEditing("name");
            }}
            onKeyDown={(e: KeyboardEvent<HTMLSpanElement>) => {
              if (e.target !== e.currentTarget) return;
              if (e.key !== "Enter" && e.key !== " ") return;
              e.preventDefault();
              setEditing(editing === "name" ? null : "name");
            }}
          >
            <span className="mt-1 text-emerald-600 dark:text-emerald-400" aria-hidden="true">
              <BotanicalIcon kind="grove" className="w-6 h-6" />
            </span>
            {title}
          </span>
        ) : (
          <span className="flex items-start gap-2">
            <span className="mt-1 text-emerald-600 dark:text-emerald-400" aria-hidden="true">
              <BotanicalIcon kind="grove" className="w-6 h-6" />
            </span>
            <Heading className="text-2xl font-semibold text-zinc-800 dark:text-zinc-100">{name}</Heading>
          </span>
        )}

        {/* The Initiative's unit count — the system root's branch badge, the
            rows' component. Outside the edit signifier so it never reads as
            part of the name. */}
        {counts !== null && calc !== null && counts.total > 0 && (
          <UnitBadge
            id="initiative-unit-count"
            doneId="initiative-done-count"
            calc={calc}
            total={counts.total}
            done={counts.done}
            className="flex-none relative top-[-0.4em] mt-2"
          />
        )}
        {canEdit && onAddRoot !== undefined && (
          <button
            type="button"
            data-add-root
            onClick={onAddRoot}
            className="mt-1 ml-auto hidden lg:inline-flex items-center gap-1 px-2 py-0.5 rounded text-sm font-bold border border-emerald-600 dark:border-emerald-500 text-emerald-700 dark:text-emerald-400 hover:bg-emerald-50 dark:hover:bg-emerald-900/30"
            aria-label="New list"
            title="New list"
          >
            <Icon name="plus" className="w-4 h-4" />
            <span>New List</span>
          </button>
        )}
      </div>

      {loading ? (
        // Sized line for line against the real header, so the box does not
        // change height when the read lands (item 4.6).
        <div id="initiative-header-skeleton" role="status" aria-busy="true">
          <span className="sr-only">Loading…</span>
          <div
            aria-hidden="true"
            className="mt-0.5 h-5 w-48 animate-pulse rounded bg-zinc-100 motion-reduce:animate-none dark:bg-zinc-800"
          />
          <div
            aria-hidden="true"
            className="absolute bottom-1 left-0 right-0 h-4 animate-pulse rounded-full bg-zinc-100 motion-reduce:animate-none dark:bg-zinc-800"
          />
        </div>
      ) : (
        <>
          {editing === "subtitle" ? (
            <p data-initiative-subtitle-body className="mt-0.5">
              <InlineField
                id="initiative-subtitle-field"
                label="Subtitle"
                value={subtitle ?? ""}
                className="text-sm text-zinc-700 dark:text-zinc-200"
                onCommit={(value) => commit({ subtitle: value })}
                onCancel={() => setEditing(null)}
              />
            </p>
          ) : (
            subtitle !== null &&
            subtitle !== "" && (
              <p
                data-initiative-subtitle-body
                data-edit-initiative
                data-keep="editor-signifier"
                title={editable ? EDIT_SUBTITLE_TITLE : undefined}
                className={[
                  "text-sm text-zinc-500 dark:text-zinc-400 mt-0.5",
                  editable ? "cursor-pointer hover:text-zinc-700 dark:hover:text-zinc-200" : "",
                ]
                  .filter((part) => part !== "")
                  .join(" ")}
                onClick={editable ? () => setEditing("subtitle") : undefined}
              >
                {subtitle}
              </p>
            )
          )}

          <div
            className="absolute bottom-1 left-0 right-0 h-4 bg-zinc-100 dark:bg-zinc-800 rounded-full overflow-hidden"
            role="progressbar"
            aria-valuenow={progress}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-label={`Initiative progress: ${progress}%`}
            style={{ "--progress": `${progress}%` } as CSSProperties}
          >
            <div
              className="absolute inset-y-0 left-0 bg-emerald-400 rounded-full"
              style={{ width: "var(--progress)" }}
            />
            <span className="absolute inset-0 flex items-center justify-center text-xs font-semibold text-zinc-900 dark:text-zinc-50 progress-bar-text">
              {progress}%
            </span>
          </div>
        </>
      )}
    </div>
  );
}

/**
 * The field a click-to-edit line becomes: the same text, editable in place.
 * Enter and leaving the field commit; Escape puts the line back unchanged.
 */
function InlineField({
  id,
  label,
  value,
  className,
  onCommit,
  onCancel,
}: {
  id: string;
  label: string;
  value: string;
  className: string;
  onCommit: (value: string) => void;
  onCancel: () => void;
}) {
  const [draft, setDraft] = useState(value);
  // Set once the field exists, so a cancel never fires a commit on the way out.
  const [done, setDone] = useState(false);

  const finish = (): void => {
    if (done) return;
    setDone(true);
    onCommit(draft);
  };

  return (
    <input
      id={id}
      type="text"
      aria-label={label}
      value={draft}
      autoFocus
      className={`w-full min-w-0 bg-transparent outline-none border-b border-emerald-500 ${className}`}
      onChange={(e) => setDraft(e.target.value)}
      onBlur={finish}
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e: KeyboardEvent<HTMLInputElement>) => {
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          finish();
        } else if (e.key === "Escape") {
          e.preventDefault();
          setDone(true);
          onCancel();
        }
      }}
    />
  );
}
