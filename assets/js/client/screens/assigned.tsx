// Assigned to you (m04.01 item 3.2).
//
// The route exists and is deep-linkable now; the list it will hold belongs to a
// later arc. A placeholder that says so beats a route that 404s.

import { ROUTE_HEADING_ID } from "../router/router.tsx";
import { Heading } from "./chrome.tsx";

export function AssignedScreen() {
  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      <Heading>Assigned to you</Heading>
      <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
        Tasks assigned to you across every Initiative will appear here.
      </p>
    </section>
  );
}
