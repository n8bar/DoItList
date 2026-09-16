// The connection summary (item 4.3, spec §7).
//
// One badge, six states, each with its own words and its own icon — never a
// colour on its own. It sits where the LiveView's `connecting_signifier/1`
// sits: bottom-left on narrow, centred in the header band from `lg:` up, and
// out of flow at every width, so it cannot push anything around when it
// changes (item 4.6).
//
// The badge's buttons sit OUTSIDE its live region: a live region announces
// itself whenever its text changes, and a control read out that way — "Try
// again" with no subject — is noise.
//
// It is a summary, not a takeover. Even at its worst — an unrecoverable client
// error — the content on screen stays readable and the badge offers the way
// out (Reload), with Dismiss to put the real connection state back. When the client has stopped retrying, Retry is here: that is
// the ONLY thing that restarts the connection (`connection.retry()`), so
// without this badge the state machine's exit is unreachable.
//
// The local-copy line hangs underneath it, because "we're live but this browser
// keeps nothing" is one situation the user is in, not two.

import { useServices } from "../services.tsx";
import type { RecoveryState } from "../state/recovery.ts";
import { clearFatalError } from "../state/recovery.ts";
import { useStoreValue } from "../state/use_store.ts";
import type { SummaryTone } from "./connection_model.ts";
import { describeConnection, storageLine, summaryState } from "./connection_model.ts";
import { Icon } from "./icon.tsx";

const selectSummary = (state: RecoveryState) => ({
  connection: state.connection,
  pendingCount: state.pendingWrites.length,
  fatal: state.fatalError,
  storage: state.storage,
  storageNote: state.storageNote,
});

/** Border, fill and text for each tone, in both themes. */
const TONE: Record<SummaryTone, string> = {
  busy: "border-amber-300 bg-amber-100 text-amber-900 shadow-lg dark:border-amber-700/70 dark:bg-amber-950/90 dark:text-amber-100",
  live: "border-transparent bg-transparent text-zinc-500 dark:text-zinc-400",
  warn: "border-amber-400 bg-amber-100 text-amber-900 shadow-lg dark:border-amber-600 dark:bg-amber-950/90 dark:text-amber-100",
  danger:
    "border-red-300 bg-red-50 text-red-900 shadow-lg dark:border-red-700/70 dark:bg-red-950/90 dark:text-red-100",
};

/** The action button, toned to sit inside its badge. */
const ACTION =
  "inline-flex min-h-11 items-center rounded-lg border border-current/40 px-2.5 py-1 text-sm font-medium transition-colors motion-reduce:transition-none hover:bg-black/5 active:bg-black/10 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-current dark:hover:bg-white/10 dark:active:bg-white/20 sm:min-h-8";

export function ConnectionSummary() {
  const { stores, connection } = useServices();
  const view = useStoreValue(stores.recovery, selectSummary);

  const shown = describeConnection(
    summaryState({
      connection: view.connection,
      pendingCount: view.pendingCount,
      fatal: view.fatal,
    }),
    view.pendingCount,
  );
  const storage = storageLine(view.storage, view.storageNote);

  return (
    <div
      id="client-connection"
      data-conn-state={shown.state}
      className={[
        "pointer-events-none fixed bottom-4 left-4 z-50 flex max-w-[calc(100vw-2rem)] flex-col items-start gap-1",
        // In the header band it sits BEHIND the header's own controls: the two
        // can meet at narrow desktop widths, and the badge must not print over a
        // nav button when they do.
        "lg:absolute lg:bottom-auto lg:left-1/2 lg:top-1/2 lg:z-0 lg:max-w-sm lg:-translate-x-1/2 lg:-translate-y-1/2",
      ].join(" ")}
    >
      <div
        data-conn-badge
        className={[
          "pointer-events-auto inline-flex items-center gap-2 rounded-full border px-3 py-1.5 font-medium",
          shown.quiet ? "text-xs" : "text-sm",
          TONE[shown.tone],
        ].join(" ")}
      >
        {/*
          The live region holds the STATE, and nothing else. A button inside it
          is re-announced every time the label changes, and "Try again" read out
          on its own tells the user nothing (§4.1).
        */}
        <span role="status" aria-live="polite" className="inline-flex items-center gap-2">
          <Icon name={shown.icon} spin={shown.spin} />
          <span data-conn-text>{shown.label}</span>
        </span>

        {shown.action === "retry" && (
          <button
            type="button"
            id="client-connection-retry"
            className={ACTION}
            onClick={() => connection.retry()}
          >
            Try again
          </button>
        )}
        {shown.action === "reload" && (
          <button
            type="button"
            id="client-connection-reload"
            className={ACTION}
            onClick={() => window.location.reload()}
          >
            Reload
          </button>
        )}
        {shown.state === "error" && (
          <button
            type="button"
            id="client-connection-dismiss"
            className={ACTION}
            onClick={() => clearFatalError(stores.recovery)}
          >
            Dismiss
          </button>
        )}
      </div>

      {shown.detail !== null && (
        <p
          id="client-connection-detail"
          className="pointer-events-auto max-w-xs rounded-lg bg-white/90 px-2 py-1 text-xs text-zinc-600 shadow-sm dark:bg-zinc-900/90 dark:text-zinc-300"
        >
          {shown.detail}
        </p>
      )}

      {storage !== null && (
        <p
          id="client-storage-note"
          className="pointer-events-auto max-w-xs rounded-lg bg-white/90 px-2 py-1 text-xs text-zinc-600 shadow-sm dark:bg-zinc-900/90 dark:text-zinc-300"
        >
          {storage}
        </p>
      )}
    </div>
  );
}
