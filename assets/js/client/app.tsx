// The client's first painted screen (m04.01 items 2.4–2.6).
//
// Everything here is interactive the instant it paints: the navigation and the
// theme toggle are local state, and the session check runs in an effect AFTER
// mount — a round trip never stands between the user and a control
// (UX_GUARDRAILS §6.7). Task 4 adds real routing and Task 6 the real frame;
// this is the minimum honest shell.
import type { ReactNode } from "react";
import { useEffect, useMemo, useRef, useState } from "react";

import type { Bootstrap, ClientState } from "./boot.ts";
import { initialState, loginPath, stateForErrorCode } from "./boot.ts";
import type { SessionData } from "./api/client.ts";
import { createApiClient } from "./api/client.ts";
import type { ThemePreference } from "./lib/theme.ts";
import { browserThemeEnv, currentPreference, nextPreference, setTheme } from "./lib/theme.ts";

type Section = "initiatives" | "account";
type SessionStatus = "checking" | "loaded" | "unavailable";

const THEME_LABEL: Record<ThemePreference, string> = {
  system: "System",
  light: "Light",
  dark: "Dark",
};

const CARD =
  "max-w-md w-full rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-6 shadow-sm";
const BUTTON =
  "inline-flex items-center rounded-lg px-3 py-1.5 text-sm font-medium transition-colors hover:bg-zinc-100 dark:hover:bg-zinc-800";
const PRIMARY =
  "inline-flex items-center rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white transition-colors hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white";

function ThemeToggle() {
  const [preference, setPreference] = useState<ThemePreference>(() =>
    currentPreference(browserThemeEnv()),
  );

  return (
    <button
      type="button"
      id="client-theme-toggle"
      aria-label="Switch theme"
      title={`Theme: ${THEME_LABEL[preference]}`}
      className={BUTTON}
      onClick={() => {
        const next = nextPreference(preference);
        setTheme(next, browserThemeEnv());
        setPreference(next);
      }}
    >
      {THEME_LABEL[preference]}
    </button>
  );
}

function Header({ section, onSection }: { section: Section; onSection: (s: Section) => void }) {
  const tab = (value: Section, label: string) => (
    <button
      type="button"
      id={`client-nav-${value}`}
      aria-current={section === value ? "page" : undefined}
      className={[
        BUTTON,
        section === value ? "bg-zinc-100 text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100" : "",
      ].join(" ")}
      onClick={() => onSection(value)}
    >
      {label}
    </button>
  );

  return (
    <header
      id="client-header"
      className="flex items-center gap-2 border-b border-zinc-200 px-4 py-3 dark:border-zinc-800"
    >
      <span className="mr-2 text-sm font-semibold tracking-tight">Do It List</span>
      {tab("initiatives", "Initiatives")}
      {tab("account", "Account")}
      <span className="flex-1" />
      <ThemeToggle />
    </header>
  );
}

function Screen({ title, children }: { title: string; children: ReactNode }) {
  return (
    <div className="flex min-h-dvh items-center justify-center p-6">
      <div className={CARD}>
        <h1 className="text-lg font-semibold text-zinc-900 dark:text-zinc-100">{title}</h1>
        <div className="mt-2 text-sm text-zinc-600 dark:text-zinc-400">{children}</div>
      </div>
    </div>
  );
}

export function App({ bootstrap }: { bootstrap: Bootstrap }) {
  const [state, setState] = useState<ClientState>(() => initialState({ ok: true, bootstrap }));
  const [section, setSection] = useState<Section>("initiatives");
  const [status, setStatus] = useState<SessionStatus>("checking");
  const [email, setEmail] = useState<string | null>(bootstrap.user?.email ?? null);

  const api = useMemo(() => createApiClient({ csrfToken: bootstrap.csrfToken }), [bootstrap]);
  const started = useRef(false);

  useEffect(() => {
    if (state.kind !== "ready" || started.current) return;
    started.current = true;

    let live = true;
    void api.get<SessionData>("/session").then((result) => {
      if (!live) return;
      if (result.ok) {
        setEmail(result.data.user.email);
        setStatus("loaded");
        return;
      }
      const next = stateForErrorCode(result.error.code, result.error.message);
      if (next) setState(next);
      else setStatus("unavailable");
    });

    return () => {
      live = false;
    };
  }, [api, state.kind]);

  if (state.kind === "signed-out") {
    return (
      <Screen title="Signed out">
        <p>Your session has ended. Sign in again to pick up where you left off.</p>
        <a id="client-sign-in" className={`${PRIMARY} mt-5`} href={loginPath(bootstrap.path)}>
          Sign in
        </a>
      </Screen>
    );
  }

  if (state.kind === "forbidden") {
    return (
      <Screen title="You don’t have access">
        <p>This Initiative isn’t shared with you.</p>
        <a id="client-back-to-initiatives" className={`${PRIMARY} mt-5`} href="/app/initiatives">
          Back to Initiatives
        </a>
      </Screen>
    );
  }

  if (state.kind === "start-failed") {
    return (
      <Screen title="Do It List couldn’t start">
        <p>{state.message}</p>
        <button
          type="button"
          id="client-reload"
          className={`${PRIMARY} mt-5`}
          onClick={() => window.location.reload()}
        >
          Reload
        </button>
      </Screen>
    );
  }

  return (
    <div className="flex min-h-dvh flex-col">
      <Header section={section} onSection={setSection} />
      <main id="client-main" className="flex-1 p-6 text-sm text-zinc-600 dark:text-zinc-400">
        <p className="font-medium text-zinc-900 dark:text-zinc-100">
          {section === "initiatives" ? "Initiatives" : "Account"}
        </p>
        <p id="client-session-status" className="mt-2" role="status">
          {status === "checking" && "Checking your session…"}
          {status === "loaded" && `Loaded · signed in as ${email ?? "—"}`}
          {status === "unavailable" && "Loaded · couldn’t reach the server for a session check."}
        </p>
      </main>
    </div>
  );
}
