// Entry point for the React client served at /app (m04.01 worklist 2).
//
// Startup is guarded end to end: a bad bootstrap payload, a throw during
// mount, or an error/rejection before the first paint all land on the same
// plain-DOM recovery screen instead of leaving the server's spinner turning
// forever. Once the client paints, it tells the document's watchdog to stand
// down by setting `window.__doit_client_ready`.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import { App } from "./app.tsx";
import { parseBootstrap } from "./boot.ts";
import { failureMessage, showRecovery } from "./lib/recovery.ts";

const START_FAILED_TITLE = "Do It List couldn’t start";

function fail(error: unknown): void {
  if (window.__doit_client_ready) return;
  window.__doit_boot_failed = true;
  showRecovery(START_FAILED_TITLE, failureMessage(error));
}

const onError = (event: ErrorEvent) => fail(event.error ?? event.message);
const onRejection = (event: PromiseRejectionEvent) => fail(event.reason);

window.addEventListener("error", onError);
window.addEventListener("unhandledrejection", onRejection);

try {
  const container = document.getElementById("app");
  if (!container) throw new Error("The page had no mount point for the app.");

  const result = parseBootstrap(document.getElementById("bootstrap")?.textContent);
  if (!result.ok) throw new Error(result.message);

  createRoot(container).render(
    <StrictMode>
      <App bootstrap={result.bootstrap} />
    </StrictMode>,
  );

  window.__doit_client_ready = true;
  window.removeEventListener("error", onError);
  window.removeEventListener("unhandledrejection", onRejection);
} catch (error) {
  fail(error);
}
