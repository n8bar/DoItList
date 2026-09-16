// What this member may do here (m04.02 item 1.2.3).
//
// The rule the server states once, in `DoIt.Initiatives`: an owner or an editor
// may edit; only an owner may administer. Nothing in the client renders from a
// raw role string — a row asks `canEdit`, not `role === "owner" || …`, so the
// three places that would otherwise each spell the rule out cannot drift apart.
//
// Viewer+ (m02.05 item 12.6) is the one permission a role alone cannot answer:
// a viewer who *leads* a task may move that task's Progress, even though they
// may not edit anything. It takes two facts the role does not carry — the
// Initiative's `viewer_plus` setting and the ids that viewer leads — so they are
// arguments, and `canProgress` is asked per task rather than once per screen.

import type { Role } from "../api/types.ts";

export interface Permissions {
  /** Add, rename, move, delete — `Initiatives.can_edit?/1`. */
  readonly canEdit: boolean;
  /** Members, settings, deletion — `Initiatives.can_admin?/1`. */
  readonly canAdmin: boolean;
  /** This viewer is elevated on the tasks they lead. */
  readonly viewerPlus: boolean;
  /** The tasks a viewer+ leads. Empty for everyone else. */
  readonly ledTaskIds: ReadonlySet<number>;
}

export interface ViewerPlusFacts {
  /** The Initiative's `viewer_plus` setting. */
  readonly enabled?: boolean;
  /** The task ids this viewer leads (`Tasks.viewer_plus_led_ids/2`). */
  readonly ledTaskIds?: readonly number[];
}

const NO_IDS: ReadonlySet<number> = new Set<number>();

/**
 * The permissions a role carries. An unknown or missing role — the read has not
 * landed, or the server sent something this client does not know — is read as
 * the least powerful thing it could be, never as an editor.
 */
export function permissionsFor(role: Role | null | undefined, facts: ViewerPlusFacts = {}): Permissions {
  const canEdit = role === "owner" || role === "editor";
  const canAdmin = role === "owner";
  const viewerPlus = role === "viewer" && facts.enabled === true;
  const led = viewerPlus && facts.ledTaskIds !== undefined ? new Set(facts.ledTaskIds) : NO_IDS;

  return { canEdit, canAdmin, viewerPlus, ledTaskIds: led };
}

/**
 * May this member move that task's Progress? Everyone who can edit, plus a
 * viewer+ on a task they lead — the same question `task_node/1` asks as
 * `can_progress` before it draws the checkbox and the bar.
 */
export function canProgress(permissions: Permissions, taskId: number): boolean {
  return permissions.canEdit || permissions.ledTaskIds.has(taskId);
}
