// Sign out (m04.01 items 3.6, 4.1).
//
// It lives in the frame, not on a screen: ending the session is something you
// can do from wherever you are, not somewhere you have to navigate to first.
//
// The behaviour is Task 5's, unchanged. The local cache is purged BEFORE the
// request that ends the session, so the next person to use this browser profile
// cannot find this account's Initiatives in it (spec §12) — and the purge is
// bounded, because a store that will not delete must never be able to keep
// somebody signed in. The press is acknowledged on the spot (§6.7); the purge
// and the request follow.

import { useRef, useState } from "react";

import { useServices } from "../services.tsx";
import { controlClass } from "./button_styles.ts";
import { runSignOut } from "./sign_out_flow.ts";

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
  const { api, cache } = useServices();
  const form = useRef<HTMLFormElement | null>(null);
  const [signingOut, setSigningOut] = useState(false);

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
        setSigningOut(true);
        void runSignOut({
          cache,
          submit: () => form.current?.submit(),
          ...(onSubmitted === undefined ? {} : { afterSubmit: onSubmitted }),
        });
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
    </form>
  );
}
