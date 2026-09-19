// Which actions may be queued offline, and which need the server now
// (m04.03 5.3, spec §5).
//
// One table. Queueable actions carry stable ids and rebase later: an edit, an
// add, a toggle, a move, a sort, a delete all go to the journal while the
// client is offline and are sent when it is back. The others need a fact only
// the server has — undo and redo act on the server's stack, members and
// imports are the server's to admit, a read has nothing to show until it has
// read, sign-in and sign-out end or start a session the server holds. Offline,
// those are shown unavailable IN PLACE, never hidden and never a silent no-op:
// a keyboard that reaches one anyway gets the inline notice.

import type { TreeIntent } from "./context.ts";

export type ActionKind =
  | TreeIntent["kind"]
  | "add"
  | "editInitiative"
  | "undo"
  | "redo"
  | "manageMembers"
  | "import"
  | "history"
  | "activity"
  | "comments"
  | "signIn"
  | "signOut";

export type ActionClass = "queueable" | "needs-server";

const NEEDS_SERVER: ReadonlySet<ActionKind> = new Set<ActionKind>([
  "undo",
  "redo",
  "manageMembers",
  "import",
  "history",
  "activity",
  "comments",
  "signIn",
  "signOut",
]);

export function actionClass(kind: ActionKind): ActionClass {
  return NEEDS_SERVER.has(kind) ? "needs-server" : "queueable";
}

/** The inline answer when a needs-server action is invoked offline anyway. */
export const NOT_AVAILABLE_OFFLINE = "Not available offline";

/** May `kind` be taken right now? Everything, unless offline and server-gated. */
export function availableOffline(kind: ActionKind, offline: boolean): boolean {
  return !offline || actionClass(kind) === "queueable";
}

/**
 * A control's accessible name while it cannot act: the name it always has,
 * with the reason — so "Undo — not available offline" is what a screen reader
 * says and what the tooltip shows, and the control is still there to find.
 */
export function unavailableLabel(label: string): string {
  return `${label} — ${NOT_AVAILABLE_OFFLINE.charAt(0).toLowerCase()}${NOT_AVAILABLE_OFFLINE.slice(1)}`;
}
