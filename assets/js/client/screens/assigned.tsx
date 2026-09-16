// Assigned to you (m04.01 items 3.2, 4.1).
//
// The route exists and is deep-linkable now; the list it will hold belongs to a
// later arc. It says so plainly rather than showing a skeleton — a placeholder
// that pretends to be loading something nobody is fetching is the client lying
// to the user.

import { ROUTE_HEADING_ID } from "../router/router.tsx";
import { Heading } from "./chrome.tsx";

export function AssignedScreen() {
  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      <Heading>Assigned to Me</Heading>
      <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
        Tasks assigned to you across every Initiative will appear here.
      </p>
    </section>
  );
}
