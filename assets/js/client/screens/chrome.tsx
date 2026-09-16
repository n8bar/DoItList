// The small pieces every screen shares (m04.01 items 3.2–3.3, 4.6).
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

export function Heading({ children }: { children: ReactNode }) {
  return (
    <h1
      id={ROUTE_HEADING_ID}
      tabIndex={-1}
      className="text-xl font-semibold tracking-tight text-zinc-900 outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 dark:text-zinc-100 dark:focus-visible:ring-emerald-400"
    >
      {children}
    </h1>
  );
}

export function ErrorNote({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div
      id="screen-error"
      role="alert"
      className="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900 dark:border-amber-700/60 dark:bg-amber-950/40 dark:text-amber-100"
    >
      <p>{message}</p>
      <button
        type="button"
        id="screen-error-retry"
        onClick={onRetry}
        className="mt-3 inline-flex min-h-11 items-center rounded-lg border border-amber-400 px-3 py-1.5 font-medium transition-colors motion-reduce:transition-none hover:bg-amber-100 active:bg-amber-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-600 dark:border-amber-600 dark:hover:bg-amber-900/40 dark:active:bg-amber-900/60 sm:min-h-9"
      >
        Try again
      </button>
    </div>
  );
}
