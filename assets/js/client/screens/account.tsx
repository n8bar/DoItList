// Account (m04.01 items 3.2, 3.6).
//
// Reads the signed-in user out of the domain store — the same record the
// session read filled in, not a second copy held by this screen.
//
// Signing out is where the local cache dies. The purge runs BEFORE the request
// that ends the session, so the next person to use this browser profile cannot
// find this account's Initiatives in it (spec §12). It is bounded: a store that
// will not delete must never be able to keep somebody signed in, so the request
// goes either way and the boot sweep tries again.

import { useRef, useState } from "react";

import { signOutPurge } from "../storage/account.ts";
import type { DomainState } from "../state/domain.ts";
import { useStoreValue } from "../state/use_store.ts";
import { useServices } from "../services.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import { Heading } from "./chrome.tsx";

const selectUser = (state: DomainState) => state.user;

export function AccountScreen() {
  const { api, cache, stores } = useServices();
  const user = useStoreValue(stores.domain, selectUser);
  const form = useRef<HTMLFormElement | null>(null);
  const [signingOut, setSigningOut] = useState(false);

  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      <Heading>Account</Heading>
      <p id="account-email" className="mt-4 text-sm text-zinc-600 dark:text-zinc-300">
        Signed in as{" "}
        <span className="font-medium text-zinc-900 dark:text-zinc-100">{user?.email ?? "—"}</span>
      </p>
      <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
        Account settings still live on the current pages; they move here in a later arc.
      </p>

      <form
        id="account-sign-out-form"
        ref={form}
        method="post"
        action="/users/log_out"
        className="mt-8"
        onSubmit={(event) => {
          event.preventDefault();
          if (signingOut) return;
          // Acknowledged on the spot; the purge and the request follow
          // (UX_GUARDRAILS §6.7).
          setSigningOut(true);
          void signOutPurge(cache, () => form.current?.submit());
        }}
      >
        <input type="hidden" name="_method" value="delete" />
        <input type="hidden" name="_csrf_token" value={api.csrfToken()} />
        <button
          type="submit"
          id="account-sign-out"
          disabled={signingOut}
          aria-busy={signingOut}
          className="inline-flex items-center rounded-lg border border-zinc-300 px-3 py-1.5 text-sm font-medium text-zinc-700 transition-colors hover:bg-zinc-100 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-200 dark:hover:bg-zinc-800"
        >
          {signingOut ? "Signing out…" : "Sign out"}
        </button>
      </form>
    </section>
  );
}
