// The small pieces every screen shares (m04.01 items 3.2–3.3, 4.6).
//
// In-place failure and empty states moved to `ui/feedback.tsx` (item 4.3),
// where every screen shares one `InlineError` and one `EmptyState` instead of
// a per-screen idea of what a failure looks like.
//
// `Heading` is the one element the router moves focus to on a navigation, so
// keyboard and screen-reader users land on the content instead of wherever the
// previous screen's DOM left them. It is `tabindex="-1"`: programmatically
// focusable, never in the tab order.
//
// Every route renders its heading through this, and at the same size and
// spacing, so the first line of every screen sits in exactly the same place —
// changing route must not nudge the page (item 4.6).

import type { ReactNode } from "react";

import { ROUTE_HEADING_ID } from "../router/router.tsx";

export function Heading({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <h1
      id={ROUTE_HEADING_ID}
      tabIndex={-1}
      // A screen ported from a LiveView template keeps that template's heading
      // classes (m04.02 item 4.1); the focus behaviour is the same either way.
      className={[
        className ?? "text-xl font-semibold tracking-tight text-zinc-900 dark:text-zinc-100",
        "outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 dark:focus-visible:ring-emerald-400",
      ].join(" ")}
    >
      {children}
    </h1>
  );
}
