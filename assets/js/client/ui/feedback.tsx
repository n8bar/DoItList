// What a region shows when it has no content to show (item 4.3).
//
// Three states, three components, and none of them is a blank space:
//
//   * `Skeleton` — the data is coming. It is `frame/skeleton.tsx`, re-exported
//     here so a screen has one place to reach for feedback: the reserved height
//     it draws is the layout budget (item 4.6), which is exactly why there is
//     only one of it.
//   * `InlineError` — the read failed, said in the region that failed, with the
//     way to try again right there (guardrails §2.3). NOT a whole-app takeover:
//     a flaky network must never cost the user the screen they were on.
//   * `EmptyState` — there is genuinely nothing, and the user is told what to
//     do about it (§2.4).

import type { ReactNode } from "react";

import { Skeleton } from "../frame/skeleton.tsx";
import { Icon } from "./icon.tsx";

export { Skeleton };

export interface InlineErrorProps {
  /** Defaults to the id the whole client has used for the in-place error. */
  id?: string;
  /** What happened, in the user's terms. */
  message: string;
  /** Try the thing again. Shown as "Try again" unless a better verb is given. */
  onRetry?: () => void;
  retryLabel?: string;
}

export function InlineError({ id, message, onRetry, retryLabel = "Try again" }: InlineErrorProps) {
  return (
    <div
      id={id ?? "screen-error"}
      role="alert"
      className="mt-4 rounded-lg border border-amber-300 bg-amber-50 p-4 text-sm text-amber-900 dark:border-amber-700/60 dark:bg-amber-950/40 dark:text-amber-100"
    >
      <p className="flex items-start gap-2">
        <Icon name="exclamation-circle" className="mt-0.5 size-5 flex-none" />
        <span>{message}</span>
      </p>
      {onRetry !== undefined && (
        <button
          type="button"
          id={`${id ?? "screen-error"}-retry`}
          onClick={onRetry}
          className="mt-3 inline-flex min-h-11 items-center rounded-lg border border-amber-400 px-3 py-1.5 font-medium transition-colors motion-reduce:transition-none hover:bg-amber-100 active:bg-amber-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-amber-600 dark:border-amber-600 dark:hover:bg-amber-900/40 dark:active:bg-amber-900/60 sm:min-h-9"
        >
          {retryLabel}
        </button>
      )}
    </div>
  );
}

export interface EmptyStateProps {
  id?: string;
  /** One line naming what is not here. */
  title: string;
  /** What to do about it. An empty screen with no way forward is a dead end. */
  children?: ReactNode;
}

export function EmptyState({ id, title, children }: EmptyStateProps) {
  return (
    <div
      {...(id === undefined ? {} : { id })}
      className="mt-4 rounded-lg border border-dashed border-zinc-300 p-6 text-sm dark:border-zinc-700"
    >
      <p className="font-medium text-zinc-800 dark:text-zinc-200">{title}</p>
      {children !== undefined && (
        <div className="mt-1 text-zinc-500 dark:text-zinc-400">{children}</div>
      )}
    </div>
  );
}
