// Signing out, in the order that actually ends the session (fix round 1).
//
// The bug this exists to prevent: the frame's Sign out lives inside the narrow
// menu, and the menu's panel is unmounted when it closes. Closing the menu
// BEFORE the request goes takes the form out of the document, and
// `signOutPurge` always waits at least a microtask before it submits — so the
// submit landed on a detached form and did nothing. The local cache was wiped,
// the session was not ended, and the user was told nothing.
//
// So the order is fixed here, once, and tested: purge, submit, and only then
// tell the caller it may tidy up its UI.

import { signOutPurge } from "../storage/account.ts";

/**
 * Whether Sign out must ask first (m04.03 2.4.1): only when the device holds
 * work the server has not acknowledged. Zero pending, no question.
 */
export function confirmSignOut(pendingCount: number): boolean {
  return pendingCount > 0;
}

/** What the question says about the work that would go. */
export function unsavedSentence(pendingCount: number): string {
  return pendingCount === 1
    ? "One change hasn’t reached the server yet. Signing out now discards it."
    : `${pendingCount} changes haven’t reached the server yet. Signing out now discards them.`;
}

export interface SignOutFlow {
  readonly cache: { purge(): Promise<boolean> };
  /** Sends `DELETE /users/log_out`. Must run while the form is still mounted. */
  readonly submit: () => void;
  /** UI tidy-up (closing the menu). Runs strictly AFTER `submit`. */
  readonly afterSubmit?: () => void;
  readonly timeoutMs?: number;
}

/** Resolves with whether the purge finished before its bound ran out. */
export function runSignOut(flow: SignOutFlow): Promise<boolean> {
  const submitThenTidy = () => {
    flow.submit();
    flow.afterSubmit?.();
  };

  return flow.timeoutMs === undefined
    ? signOutPurge(flow.cache, submitThenTidy)
    : signOutPurge(flow.cache, submitThenTidy, flow.timeoutMs);
}
