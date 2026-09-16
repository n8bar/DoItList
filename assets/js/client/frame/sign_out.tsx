// Sign out (m04.01 items 3.6, 4.1).
//
// It lives in the frame, not on a screen: ending the session is something you
// can do from wherever you are, not somewhere you have to navigate to first.
//
// One confirm, and only one: signing out with writes that have not reached the
// server yet would discard work the user cannot see (UX_GUARDRAILS §6.3 — an
// effect that lands off-screen). It is asked client-side from a count the
// client already holds, so nothing waits on the network to be asked (§6.5).
//
// The behaviour is Task 5's, unchanged. The local cache is purged BEFORE the
// request that ends the session, so the next person to use this browser profile
// cannot find this account's Initiatives in it (spec §12) — and the purge is
// bounded, because a store that will not delete must never be able to keep
// somebody signed in. The press is acknowledged on the spot (§6.7); the purge
// and the request follow.

import { useRef, useState } from "react";

import { useServices } from "../services.tsx";
import type { RecoveryState } from "../state/recovery.ts";
import { useStoreValue } from "../state/use_store.ts";
import { ConfirmDialog } from "../ui/dialog.tsx";
import { controlClass } from "./button_styles.ts";
import { runSignOut } from "./sign_out_flow.ts";

const selectPending = (state: RecoveryState) => state.pendingWrites.length;

export interface SignOutProps {
  /** Prefix for this instance's ids — the header and the menu each render one. */
  idPrefix: string;
  /** Extra classes on the form, e.g. the breakpoint that hides this instance. */
  className?: string;
  block?: boolean;
  /**
   * UI tidy-up — the menu closes itself with this. It runs AFTER the request has
   * gone, never before: closing the menu unmounts this form, and a submit on a
   * detached form is a silent no-op (see `sign_out_flow.ts`).
   */
  onSubmitted?: () => void;
}

export function SignOut({ idPrefix, className, block, onSubmitted }: SignOutProps) {
  const { api, cache, stores } = useServices();
  const pending = useStoreValue(stores.recovery, selectPending);
  const form = useRef<HTMLFormElement | null>(null);
  const [signingOut, setSigningOut] = useState(false);
  const [confirming, setConfirming] = useState(false);

  const go = () => {
    if (signingOut) return;
    setConfirming(false);
    setSigningOut(true);
    void runSignOut({
      cache,
      submit: () => form.current?.submit(),
      ...(onSubmitted === undefined ? {} : { afterSubmit: onSubmitted }),
    });
  };

  return (
    <form
      id={`${idPrefix}-sign-out-form`}
      ref={form}
      method="post"
      action="/users/log_out"
      {...(className === undefined ? {} : { className })}
      onSubmit={(event) => {
        event.preventDefault();
        if (signingOut) return;
        // Work the server has not acknowledged goes with the session. The user
        // gets to decide that, and the question is asked here and now.
        if (pending > 0) {
          setConfirming(true);
          return;
        }
        go();
      }}
    >
      <input type="hidden" name="_method" value="delete" />
      <input type="hidden" name="_csrf_token" value={api.csrfToken()} />
      <button
        type="submit"
        id={`${idPrefix}-sign-out`}
        disabled={signingOut}
        aria-busy={signingOut}
        className={controlClass({ disabled: signingOut, ...(block === true ? { block } : {}) })}
      >
        {signingOut ? "Signing out…" : "Sign out"}
      </button>

      {/* Inside the form on purpose: the narrow menu unmounts its panel when it
          closes, and a dialog that outlives its form would be answering for a
          form that is no longer in the document. */}
      <ConfirmDialog
        id={`${idPrefix}-sign-out-confirm`}
        open={confirming}
        title="Sign out with unsaved changes?"
        confirmLabel="Sign out anyway"
        cancelLabel="Stay signed in"
        danger
        onConfirm={go}
        onCancel={() => setConfirming(false)}
      >
        {pending === 1
          ? "One change hasn’t reached the server yet. Signing out now discards it."
          : `${pending} changes haven’t reached the server yet. Signing out now discards them.`}
      </ConfirmDialog>
    </form>
  );
}
