// The decisions one task row makes, without a DOM (m04.02 items 2.1.1–2.1.4).
//
// `row.tsx` is markup; everything it would otherwise decide inline lives here,
// because these are the rules a reader compares against `task_node/1` and the
// helpers around it in `initiative_workspace_live.ex`. Each function below
// names the Elixir it mirrors.

import type { Member, ProgressCalc } from "../api/types.ts";
import { segments } from "../../refs.js";
import { avatarBackground, avatarForeground, initials } from "../frame/avatar_model.ts";
import type { Selection } from "../live/presence_model.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { childIdsOf } from "./model.ts";

/** The row's type glyph. `botanical_kind/2`: tree at the top, branch, leaf. */
export type BotanicalKind = "tree" | "branch" | "leaf";

export function botanicalKind(model: TreeModel, id: number, depth: number): BotanicalKind {
  if (depth === 0) return "tree";
  return childIdsOf(model, id).length > 0 ? "branch" : "leaf";
}

/** `botanical_color/2` — branches amber, everything else emerald. */
export function botanicalColor(kind: BotanicalKind): string {
  return kind === "branch"
    ? "text-amber-700 dark:text-amber-600"
    : "text-emerald-600 dark:text-emerald-400";
}

/**
 * The number the row shows. `progress_value/1`: a branch shows the roll-up the
 * server maintains, a done task shows 100, and a leaf shows its own input.
 */
export function progressValue(model: TreeModel, id: number): number {
  const record = model.tasks[id];
  if (record === undefined) return 0;
  if (childIdsOf(model, id).length > 0) return record.progress;
  if (record.status === "done") return 100;
  return record.manual_progress ?? 0;
}

/** `badge_icon/1` — the count badge's glyph names the roll-up mode. */
export function badgeIcon(calc: ProgressCalc): BotanicalKind {
  return calc === "single_level" ? "branch" : "leaf";
}

/** `badge_icon_class/1`. */
export function badgeIconClass(calc: ProgressCalc): string {
  return calc === "single_level"
    ? "w-3 h-3 flex-none text-amber-700 dark:text-amber-600"
    : "w-3 h-3 flex-none";
}

/** `branch_unit_title/1` — what the badge's number counts, in words. */
export function branchUnitTitle(calc: ProgressCalc): string {
  return calc === "single_level"
    ? "Direct children — each counts equally"
    : "Leaves in this branch";
}

/**
 * How many co-assignee avatars a row draws before it falls back to "+N".
 * `@co_avatar_cap` in `DoIt.Tasks`; the read sends the whole list, so the cap
 * is applied here instead of by the serializer.
 */
export const CO_AVATAR_CAP = 8;

/** Just enough of a member to draw and name. */
export interface RowUser {
  readonly id: number;
  readonly name: string | null;
  readonly username: string;
}

/** `members` as a lookup, built once per render rather than once per row. */
export function memberIndex(members: readonly Member[]): ReadonlyMap<number, RowUser> {
  return new Map(
    members.map((m) => [m.user_id, { id: m.user_id, name: m.name, username: m.username }]),
  );
}

export interface AssigneeView {
  /** The primary assignee, if the row has one we can draw. */
  readonly user: RowUser | null;
  /** Assigned to somebody who has since left — the name is struck through. */
  readonly exMember: boolean;
  /** The avatars to draw beside the "+", capped. */
  readonly coUsers: readonly RowUser[];
  /** Co-assignees beyond the cap, drawn as "+N". `0` when none overflow. */
  readonly coOverflow: number;
  /** All the co-assignees, capped or not — what the "+N" title counts. */
  readonly coCount: number;
  /** `title` on the chip: `assignee_title/2`. */
  readonly title: string;
  /** `data-pill-set` — a customized value, not the default. */
  readonly set: boolean;
}

/**
 * The assignee chip. The struck-through name is deliberate (`ex_member?/2`): a
 * member who leaves keeps their assignments, and the strike says so at a glance
 * rather than silently blanking the row.
 *
 * A co-assignee the members list does not know is dropped rather than drawn as
 * a blank disc — but it still counts, so the "+N" stays honest.
 */
export function assigneeView(record: TaskRecord, members: ReadonlyMap<number, RowUser>): AssigneeView {
  const assigneeId = record.assignee_id;
  const user = assigneeId === null ? null : (members.get(assigneeId) ?? null);
  const exMember = assigneeId !== null && user === null;

  const coCount = record.co_assignee_ids.length;
  const coUsers = record.co_assignee_ids
    .slice(0, CO_AVATAR_CAP)
    .map((uid) => members.get(uid))
    .filter((u): u is RowUser => u !== undefined);

  return {
    user,
    exMember,
    coUsers,
    coOverflow: Math.max(0, coCount - coUsers.length),
    coCount,
    title: assigneeTitle(assigneeId, user, exMember),
    set: (assigneeId !== null && user !== null) || coCount > 0,
  };
}

/** `assignee_title/2`. */
export function assigneeTitle(
  assigneeId: number | null,
  user: RowUser | null,
  exMember: boolean,
): string {
  if (assigneeId === null) return "Unassigned";
  // The LiveView has the assignee's user record preloaded even after they leave,
  // so it can still name them. The client only holds the CURRENT members, so an
  // ex-member has no username here — say what is true rather than guess a name.
  if (user === null) return "Assignee: (no longer a member)";
  return exMember
    ? `Assignee: @${user.username} (no longer a member)`
    : `Assignee: @${user.username}`;
}

/** The avatar's inline style, derived the way the server derives it. */
export function avatarStyle(user: RowUser): { backgroundImage: string; color: string } {
  return { backgroundImage: avatarBackground(user.id), color: avatarForeground(user.id) };
}

export { initials };

// --- Presence (item 3.4.2) ------------------------------------------------
//
// `applyPresenceBadges` in `app.js`, as decisions: which badges a row wears
// and whether its assignee chip gets the online dot.

/** What the tree knows about everyone else on the Initiative. */
export interface RowPresence {
  /** Other members' selections, unique per (user, task). */
  readonly selections: readonly Selection[];
  /** Everyone on the channel, self included. */
  readonly online: ReadonlySet<number>;
}

export const noPresence: RowPresence = { selections: [], online: new Set<number>() };

/** The badges a row wears — one per other member with it selected, in arrival order. */
export function rowBadges(presence: RowPresence, taskId: number): readonly Selection[] {
  return presence.selections.filter((selection) => selection.task_id === taskId);
}

/** `title` on a badge. */
export function badgeTitle(selection: Selection): string {
  return `${selection.name} has this task selected`;
}

/** Whether the assignee chip's disc gets the online dot. Unassigned never does. */
export function chipOnline(presence: RowPresence, assigneeId: number | null): boolean {
  return assigneeId !== null && presence.online.has(assigneeId);
}

// --- References -----------------------------------------------------------
//
// The `%<id>` parser is `assets/js/refs.js`, imported rather than rewritten —
// one grammar, two clients. What differs is the resolution: the LiveView reads
// each row's rendered `data-copy-index`, while here the model already knows
// every task's live label, so a re-number needs no DOM at all.

/** Classes copied from `app.js`, so `app.css` and the scan treat both alike. */
export const REF_LINK_CLASS =
  "doit-ref text-emerald-700 dark:text-emerald-400 hover:underline decoration-dotted underline-offset-2 cursor-pointer";
export const REF_DEAD_CLASS = "doit-ref-dead text-zinc-400 dark:text-zinc-500 cursor-default";

export type RefPart =
  | { readonly kind: "text"; readonly text: string }
  /** A task this tree holds. `label` is its live index, or "↗" when unnumbered. */
  | { readonly kind: "link"; readonly id: number; readonly label: string }
  /** A reference whose task is not in this tree: shown as "%?", never as raw text. */
  | { readonly kind: "dead"; readonly id: number };

/** A task's live index label, or `null` when the Initiative is not numbered. */
export function refLabelOf(model: TreeModel, id: number): string | null {
  const record = model.tasks[id];
  if (record === undefined) return null;
  return record.index === "" ? null : record.index;
}

/**
 * Prose split into what to render: literal runs (escapes resolved) and each
 * reference as a live label. `buildRefNode`'s rule exactly — a known label is
 * the number, a live-but-unnumbered task is the "↗" glyph, and anything else is
 * the dead marker.
 */
export function refParts(text: string, model: TreeModel): readonly RefPart[] {
  return segments(text).map((segment): RefPart => {
    if (segment.type === "text") return { kind: "text", text: segment.value };
    const label = refLabelOf(model, segment.id);
    if (label !== null) return { kind: "link", id: segment.id, label };
    return model.tasks[segment.id] === undefined
      ? { kind: "dead", id: segment.id }
      : { kind: "link", id: segment.id, label: "↗" };
  });
}
