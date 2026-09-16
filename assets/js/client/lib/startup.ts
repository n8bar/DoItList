// The startup guard: who gets to say "the client is up" and who gets to
// replace the screen with a recovery card (m04.01 item 2.3).
//
// Pure and JSX-free so the ordering rules — the part that is easy to get
// subtly wrong — are unit-tested rather than reasoned about:
//
//   * `markReady` is the ONLY thing that disarms the document's watchdog, and
//     it is called from inside the mounted tree, after React has committed.
//     A render that throws never commits, so ready is never signalled.
//   * `fail` (a global error/rejection before the client painted) is ignored
//     once ready — that error belongs to the running app, not to startup.
//   * `crash` (the root error boundary) is honoured EVEN after ready: React
//     unmounts the tree on an uncaught error, so the alternative is a blank
//     `#app`, which is exactly the inert markup spec §2 forbids.
//   * Either way the recovery screen is rendered at most once.

import { failureMessage } from "./recovery.ts";

export interface StartupGuardHooks {
  /** Render the recovery screen with this message. */
  onFail: (message: string) => void;
  /** The client painted: disarm the watchdog and drop the global listeners. */
  onReady: () => void;
}

export interface StartupGuard {
  /** A startup-time error. Ignored once the client is up. */
  fail(error: unknown): void;
  /** An error the root boundary caught. Honoured even after the client is up. */
  crash(error: unknown): void;
  /** Called from inside the committed tree. */
  markReady(): void;
  ready(): boolean;
  failed(): boolean;
}

export function createStartupGuard(hooks: StartupGuardHooks): StartupGuard {
  let ready = false;
  let failed = false;

  const show = (error: unknown) => {
    if (failed) return;
    failed = true;
    hooks.onFail(failureMessage(error));
  };

  return {
    fail(error) {
      if (ready) return;
      show(error);
    },
    crash(error) {
      show(error);
    },
    markReady() {
      if (failed || ready) return;
      ready = true;
      hooks.onReady();
    },
    ready: () => ready,
    failed: () => failed,
  };
}
