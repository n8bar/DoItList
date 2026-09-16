// Notices: the one line the app says to the user after the fact (item 4.3).
//
// A notice is for something the user should know but must not be interrupted
// by: a write that failed, a session check that couldn't be reached, a thing
// that saved. It is NOT how a field reports a validation error (that belongs
// next to the field, guardrail §2.2) and it is NOT how the connection reports
// itself (that is the connection summary, spec §7).
//
// Pure list operations, kept out of the store so the rules that matter — an
// error never disappears on its own, the same message never stacks up, the
// stack is bounded — are unit-tested without React.

/** Success is good news, info is a fact, error is something that went wrong. */
export type NoticeKind = "success" | "info" | "error";

export interface Notice {
  readonly id: string;
  readonly kind: NoticeKind;
  /** An optional bold first line, like the LiveView flash's title. */
  readonly title: string | null;
  readonly message: string;
}

/** How many notices may show at once. Past this the oldest makes way. */
export const MAX_NOTICES = 4;

/** How long a success notice stays before it dismisses itself. */
export const SUCCESS_DISMISS_MS = 5_000;

/**
 * Errors are announced (`alert`); everything else is stated (`status`). An
 * `alert` interrupts a screen reader, which is right for "that didn't save"
 * and wrong for "saved".
 */
export function noticeRole(kind: NoticeKind): "alert" | "status" {
  return kind === "error" ? "alert" : "status";
}

/**
 * Only success dismisses itself. An error the user never saw is an error they
 * were never told about, so it stays until they dismiss it — and info stays
 * because it is usually still true.
 */
export function autoDismissMs(kind: NoticeKind): number | null {
  return kind === "success" ? SUCCESS_DISMISS_MS : null;
}

/** The notice already showing with this kind and message, if any. */
export function findDuplicate(
  notices: readonly Notice[],
  kind: NoticeKind,
  message: string,
): Notice | null {
  return notices.find((notice) => notice.kind === kind && notice.message === message) ?? null;
}

/**
 * Newest first — the stack grows upward from the corner, so the newest notice
 * is the one nearest the user's attention. A repeat of a message already
 * showing is not a second notice: the same failure retried three times is one
 * thing that is wrong, not three.
 */
export function addNotice(notices: readonly Notice[], notice: Notice): readonly Notice[] {
  if (findDuplicate(notices, notice.kind, notice.message) !== null) return notices;
  return [notice, ...notices].slice(0, MAX_NOTICES);
}

export function removeNotice(notices: readonly Notice[], id: string): readonly Notice[] {
  const next = notices.filter((notice) => notice.id !== id);
  return next.length === notices.length ? notices : next;
}
