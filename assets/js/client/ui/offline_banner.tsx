// The one-line offline banner over the tree (m04.03 5.1.3, 5.2.2).
//
// The summary badge says the state; this says what it means for the work in
// front of the user, where that work is — and carries the same Retry, so the
// way back is never only in a badge in the corner. It draws nothing in any
// other state: it is a banner, not a slot, and an empty band over the tree
// would move the rows for no reason.

import { useServices } from "../services.tsx";
import { OFFLINE_BANNER } from "./connection_model.ts";
import { Icon } from "./icon.tsx";
import { useOffline } from "./use_degraded.ts";

const BANNER =
  "mb-3 flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-amber-400 bg-amber-100 px-3 py-1.5 text-sm text-amber-900 dark:border-amber-600 dark:bg-amber-950/90 dark:text-amber-100";

const RETRY =
  "inline-flex min-h-11 items-center rounded-lg border border-current/40 px-2.5 py-1 text-sm font-medium transition-colors motion-reduce:transition-none hover:bg-black/5 active:bg-black/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-current dark:hover:bg-white/10 dark:active:bg-white/20 sm:min-h-8";

export function OfflineBanner() {
  const { connection } = useServices();
  const offline = useOffline();
  if (!offline) return null;

  return (
    <div id="client-offline-banner" role="status" className={BANNER}>
      <span className="inline-flex items-center gap-2">
        <Icon name="signal-slash" />
        <span>{OFFLINE_BANNER}</span>
      </span>
      <button
        type="button"
        id="client-offline-banner-retry"
        className={`${RETRY} ml-auto`}
        onClick={() => connection.retry()}
      >
        Try again
      </button>
    </div>
  );
}
