// Account (m04.01 items 3.2, 4.1).
//
// Reads the signed-in user out of the domain store — the same record the
// session read filled in, not a second copy held by this screen.
//
// Sign out used to live here. It is in the frame now (`frame/sign_out.tsx`):
// ending the session is something you can do from wherever you are, not
// somewhere you have to navigate to first. The purge-then-submit behaviour went
// with it, unchanged.

import type { DomainState } from "../state/domain.ts";
import { useStoreValue } from "../state/use_store.ts";
import { useServices } from "../services.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import { Heading } from "./chrome.tsx";

const selectUser = (state: DomainState) => state.user;

export function AccountScreen() {
  const { stores } = useServices();
  const user = useStoreValue(stores.domain, selectUser);

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
      <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
        Sign out is in the header, next to the theme.
      </p>
    </section>
  );
}
