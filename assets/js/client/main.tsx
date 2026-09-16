// Entry point for the React client served at /app (m04.01 worklist 2).
//
// Startup is guarded end to end. A bad bootstrap payload, a throw before mount,
// an error or rejection while starting, and a throw *inside* the React tree all
// land on the same plain-DOM recovery screen instead of leaving the server's
// spinner turning or an empty #app behind. "The client is up" is signalled from
// inside the committed tree (ReadyBeacon), never from here — React's render work
// is scheduled, so returning from `render()` proves nothing.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./app.tsx";
import { ReadyBeacon, RootBoundary } from "./root_boundary.tsx";
import { parseBootstrap } from "./boot.ts";
import { showRecovery } from "./lib/recovery.ts";
import { createStartupGuard } from "./lib/startup.ts";

const START_FAILED_TITLE = "Do It List couldn’t start";

const onError = (event: ErrorEvent) => guard.fail(event.error ?? event.message);
const onRejection = (event: PromiseRejectionEvent) => guard.fail(event.reason);

const guard = createStartupGuard({
  onFail: (message) => {
    window.__doit_boot_failed = true;
    showRecovery(START_FAILED_TITLE, message);
  },
  onReady: () => {
    // Only now is the document's watchdog allowed to stand down.
    window.__doit_client_ready = true;
    window.removeEventListener("error", onError);
    window.removeEventListener("unhandledrejection", onRejection);
  },
});

window.addEventListener("error", onError);
window.addEventListener("unhandledrejection", onRejection);

try {
  const container = document.getElementById("app");
  if (!container) throw new Error("The page had no mount point for the app.");

  const result = parseBootstrap(document.getElementById("bootstrap")?.textContent);
  if (!result.ok) throw new Error(result.message);

  createRoot(container).render(
    <StrictMode>
      <RootBoundary onError={(error) => guard.crash(error)}>
        <App bootstrap={result.bootstrap} />
        <ReadyBeacon onReady={() => guard.markReady()} />
      </RootBoundary>
    </StrictMode>,
  );
} catch (error) {
  guard.fail(error);
}
