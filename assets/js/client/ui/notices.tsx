// The notice region (item 4.3).
//
// The LiveView's flash, in the client's own terms: an icon, an optional bold
// first line, the message, and a close control with a real accessible name.
// Errors are announced (`role="alert"`) and stay until the user dismisses them;
// success states itself (`role="status"`) and goes away on its own. Nothing
// here ever reports a field's validation error — that belongs next to the field
// (guardrails §2.2).
//
// It is fixed and out of flow at every width, so a notice arriving never pushes
// the page around (item 4.6), and it stacks upward from the bottom-left corner,
// clear of the connection summary's badge below `lg:`.

import { useEffect, useRef } from "react";

import type { Notice } from "../state/notices.ts";
import { autoDismissMs, noticeRole } from "../state/notices.ts";
import type { UiState } from "../state/ui.ts";
import { dismissNotice } from "../state/ui.ts";
import { useServices } from "../services.tsx";
import { useStoreValue } from "../state/use_store.ts";
import type { IconName } from "./icons.ts";
import { Icon } from "./icon.tsx";

const selectNotices = (state: UiState) => state.notices;

const KIND_ICON: Record<Notice["kind"], IconName> = {
  success: "check-circle",
  info: "information-circle",
  error: "exclamation-circle",
};

const KIND_STYLE: Record<Notice["kind"], string> = {
  success:
    "border-emerald-300 bg-emerald-50 text-emerald-900 dark:border-emerald-700 dark:bg-emerald-950/90 dark:text-emerald-100",
  info: "border-zinc-300 bg-white text-zinc-800 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100",
  error:
    "border-red-300 bg-red-50 text-red-900 dark:border-red-700 dark:bg-red-950/90 dark:text-red-100",
};

function NoticeCard({ notice, onDismiss }: { notice: Notice; onDismiss: () => void }) {
  const ms = autoDismissMs(notice.kind);

  // The handler is rebuilt every render; the countdown must not restart for
  // that — a success notice that keeps being re-armed never goes away.
  const latest = useRef(onDismiss);
  latest.current = onDismiss;

  useEffect(() => {
    if (ms === null) return;
    const timer = window.setTimeout(() => latest.current(), ms);
    return () => window.clearTimeout(timer);
  }, [ms, notice.id]);

  return (
    <div
      id={`notice-${notice.id}`}
      role={noticeRole(notice.kind)}
      data-kind={notice.kind}
      className={`pointer-events-auto flex w-80 max-w-[calc(100vw-2rem)] items-start gap-2 rounded-lg border p-3 text-sm shadow-lg sm:w-96 ${KIND_STYLE[notice.kind]}`}
    >
      <Icon name={KIND_ICON[notice.kind]} className="mt-0.5 size-5 flex-none" />
      <div className="min-w-0 flex-1">
        {notice.title !== null && <p className="font-semibold">{notice.title}</p>}
        <p className="break-words">{notice.message}</p>
      </div>
      <button
        type="button"
        id={`notice-${notice.id}-dismiss`}
        onClick={onDismiss}
        aria-label="Dismiss this message"
        title="Dismiss"
        className="-my-1 -mr-1 inline-flex min-h-11 min-w-11 flex-none items-center justify-center rounded-lg opacity-60 transition-opacity motion-reduce:transition-none hover:opacity-100 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-current sm:min-h-8 sm:min-w-8"
      >
        <Icon name="x-mark" className="size-5" />
      </button>
    </div>
  );
}

export function Notices() {
  const { stores } = useServices();
  const notices = useStoreValue(stores.ui, selectNotices);

  return (
    <div
      id="client-notices"
      className="pointer-events-none fixed bottom-20 left-4 z-50 flex flex-col-reverse gap-2 lg:bottom-4"
    >
      {notices.map((notice) => (
        <NoticeCard
          key={notice.id}
          notice={notice}
          onDismiss={() => dismissNotice(stores.ui, notice.id)}
        />
      ))}
    </div>
  );
}
