// The "it didn't start" screens (m04.01 item 2.3).
//
// Plain DOM, no React: these have to work when React is exactly what failed.
// The markup builder is a pure function so its escaping and its Reload control
// are unit-tested; `showRecovery` is the two-line DOM wiring around it.

export function escapeHtml(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/** A titled recovery card with a Reload button (`id="boot-reload"`). */
export function recoveryScreen(title: string, detail: string): string {
  return `
    <div class="min-h-dvh flex items-center justify-center p-6">
      <div class="max-w-md w-full rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-6 shadow-sm">
        <h1 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">${escapeHtml(title)}</h1>
        <p class="mt-2 text-sm text-zinc-600 dark:text-zinc-400">${escapeHtml(detail)}</p>
        <button type="button" id="boot-reload"
          class="mt-5 inline-flex items-center rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white">
          Reload
        </button>
      </div>
    </div>`;
}

/** Replaces the mount point with a recovery screen and wires Reload. */
export function showRecovery(title: string, detail: string): void {
  const app = document.getElementById("app");
  if (!app) return;
  app.innerHTML = recoveryScreen(title, detail);
  document
    .getElementById("boot-reload")
    ?.addEventListener("click", () => window.location.reload());
}

/** A thrown value as a sentence a person can read. */
export function failureMessage(error: unknown): string {
  if (error instanceof Error && error.message) return error.message;
  if (typeof error === "string" && error) return error;
  return "An unexpected error stopped the app from starting.";
}
