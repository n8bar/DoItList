// The client's own not-found screen (m04.01 item 3.2).
//
// The server hands every `/app/...` path the same document, so an unknown path
// is the client's to answer. It says so plainly and offers the way back rather
// than leaving the user on an empty frame.

import { Link } from "../router/link.tsx";
import { ROUTE_HEADING_ID } from "../router/router.tsx";
import { Heading } from "./chrome.tsx";

export function NotFoundScreen({ path }: { path: string }) {
  return (
    <section aria-labelledby={ROUTE_HEADING_ID}>
      <Heading>We couldn’t find that page</Heading>
      <p className="mt-4 text-sm text-zinc-500 dark:text-zinc-400">
        Nothing lives at <code className="font-mono">{path}</code>.
      </p>
      <Link
        id="not-found-home"
        to="/app/initiatives"
        className="mt-5 inline-flex items-center rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white transition-colors hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white"
      >
        Go to Initiatives
      </Link>
    </section>
  );
}
