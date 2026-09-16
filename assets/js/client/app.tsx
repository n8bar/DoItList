// The client shell (m04.01 worklists 2–3).
//
// Everything here is interactive the instant it paints: the nav, the theme
// toggle and the router are all local, and the session read runs in an effect
// AFTER mount — a round trip never stands between the user and a control
// (UX_GUARDRAILS §6.7). A route change is the same deal: the new screen is on
// the glass before anything is fetched (spec §2).
//
// The stores, the API client and the live connection are built once, outside
// the render, and handed down by context — a route change remounts screens, not
// infrastructure (guardrail §7.4).
import type { ReactNode } from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { Bootstrap, ClientState } from "./boot.ts";
import { initialState, loginPath, stateForErrorCode } from "./boot.ts";
import type { ApiError, SessionData } from "./api/client.ts";
import { createApiClient } from "./api/client.ts";
import { initConnection } from "./live/connection.ts";
import { phoenixTransport } from "./live/phoenix_transport.ts";
import { createInitiativeSync } from "./live/refresh.ts";
import { Link } from "./router/link.tsx";
import type { Route } from "./router/route.ts";
import { matchRoute } from "./router/route.ts";
import { RouterProvider, useRoute } from "./router/router.tsx";
import { RouteView } from "./screens/route_view.tsx";
import { createStores } from "./state/stores.ts";
import { setThemePreference } from "./state/preferences.ts";
import type { RecoveryState } from "./state/recovery.ts";
import { setConnectionStatus, setSnapshotMeta, setStorageHealth } from "./state/recovery.ts";
import { useStore, useStoreValue } from "./state/use_store.ts";
import type { Stores } from "./state/stores.ts";
import { ServicesProvider } from "./services.tsx";
import { openClientCache } from "./storage/client_cache.ts";
import { browserIdb } from "./storage/idb.ts";
import { browserKeyValueStore } from "./storage/last_user.ts";
import type { ThemePreference } from "./lib/theme.ts";
import { browserThemeEnv, currentPreference, nextPreference, setTheme } from "./lib/theme.ts";

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

function ThemeToggle({ stores }: { stores: Stores }) {
  const { theme } = useStore(stores.preferences);

  return (
    <button
      type="button"
      id="client-theme-toggle"
      aria-label="Switch theme"
      title={`Theme: ${THEME_LABEL[theme]}`}
      className={BUTTON}
      onClick={() => {
        const next = nextPreference(theme);
        setTheme(next, browserThemeEnv());
        setThemePreference(stores.preferences, next);
      }}
    >
      {THEME_LABEL[theme]}
    </button>
  );
}

/** True when this nav entry is the route currently showing. */
function current(route: Route, kind: Route["kind"]): boolean {
  if (route.kind === kind) return true;
  // A single Initiative still belongs under Initiatives.
  return kind === "initiatives" && route.kind === "initiative";
}

function Header({ stores }: { stores: Stores }) {
  const route = useRoute();

  const tab = (kind: Route["kind"], to: string, label: string) => (
    <Link
      id={`client-nav-${kind}`}
      to={to}
      aria-current={current(route, kind) ? "page" : undefined}
      className={[
        BUTTON,
        current(route, kind) ? "bg-zinc-100 text-zinc-900 dark:bg-zinc-800 dark:text-zinc-100" : "",
      ].join(" ")}
    >
      {label}
    </Link>
  );

  return (
    <header
      id="client-header"
      className="flex shrink-0 items-center gap-2 border-b border-zinc-200 px-4 py-3 dark:border-zinc-800"
    >
      <span className="mr-2 text-sm font-semibold tracking-tight">Do It List</span>
      <nav aria-label="Sections" className="flex items-center gap-1">
        {tab("initiatives", "/app/initiatives", "Initiatives")}
        {tab("assigned", "/app/assigned", "Assigned")}
        {tab("account", "/app/account", "Account")}
      </nav>
      <span className="flex-1" />
      <ThemeToggle stores={stores} />
    </header>
  );
}

const selectStorage = (state: RecoveryState) => ({
  health: state.storage,
  note: state.storageNote,
});

/**
 * What the user is owed when the local cache is not what it should be: one
 * sentence, in place, never a takeover. Task 7's connection summary absorbs
 * this; until then the client saying nothing would be the client knowing
 * something the user doesn't.
 */
function StorageNote({ stores }: { stores: Stores }) {
  const { health, note } = useStoreValue(stores.recovery, selectStorage);
  if (health === "opening" || health === "ready") return null;

  const headline =
    health === "unavailable"
      ? "This browser isn’t saving a local copy, so a reload starts from the server."
      : "Some of the local copy couldn’t be kept.";

  return (
    <p
      id="client-storage-note"
      role="status"
      className="shrink-0 border-b border-zinc-200 bg-zinc-50 px-4 py-2 text-xs text-zinc-600 dark:border-zinc-800 dark:bg-zinc-900 dark:text-zinc-400"
    >
      {headline}
      {note !== null && <span className="ml-1 text-zinc-500 dark:text-zinc-500">({note})</span>}
    </p>
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
  const [sessionNote, setSessionNote] = useState<string | null>(null);

  // Built once. `useState`'s initialiser, not `useMemo`, because these must not
  // be rebuilt even if React decides to discard a memo.
  const [stores] = useState<Stores>(() =>
    createStores({
      domain: { user: bootstrap.user },
      preferences: { theme: currentPreference(browserThemeEnv()) },
      ui: { route: matchRoute(bootstrap.path) },
    }),
  );
  const [api] = useState(() => createApiClient({ csrfToken: bootstrap.csrfToken }));
  // The account's local cache. Opening it is asynchronous and nothing waits on
  // it: a signed-out tab opens nothing, and a browser that refuses to give us a
  // database gets an in-memory stand-in plus a line in the UI saying so.
  const [cache] = useState(() =>
    openClientCache({
      userId: bootstrap.user?.id ?? null,
      idb: browserIdb(),
      keyValue: browserKeyValueStore(),
      onStatus: (status, reason) =>
        setStorageHealth(stores.recovery, status, reason?.message ?? null),
      onMeta: (meta) => setSnapshotMeta(stores.recovery, meta),
    }),
  );
  // The tab's one live connection. A route change must never recreate it — and
  // it opens no socket until the effect below says we have an identity, so a
  // signed-out tab never hammers a handshake it cannot pass.
  const [connection] = useState(() => {
    // One unit: a refetch in flight when access is taken away must not land
    // after the forget and put the tree back.
    const sync = createInitiativeSync({
      api,
      domain: stores.domain,
      ui: stores.ui,
      snapshots: cache,
      onForbidden: () => setState({ kind: "forbidden" }),
    });

    return initConnection({
      transport: (options) => phoenixTransport(options, () => api.csrfToken()),
      onStatus: (status) => setConnectionStatus(stores.recovery, status),
      onChanged: sync.onChanged,
      onAccessRevoked: sync.onAccessRevoked,
    });
  });

  const mainRef = useRef<HTMLElement | null>(null);
  const scrollContainer = useCallback(() => mainRef.current, []);

  /**
   * Only "your session ended" and "you can't see this" belong to the shell: a
   * whole-app takeover for a flaky network would throw away a screen the user
   * can perfectly well retry in place (§6).
   */
  const escalate = useCallback(
    (error: ApiError): boolean => {
      const next = stateForErrorCode(error.code, error.message);
      if (next !== null && (next.kind === "signed-out" || next.kind === "forbidden")) {
        // The session is over however it ended: what it cached goes with it
        // (spec §12), not just when the user pressed Sign out.
        if (next.kind === "signed-out") void cache.purge();
        setState(next);
        return true;
      }
      return false;
    },
    [cache],
  );

  const services = useMemo(
    () => ({ api, stores, connection, cache, escalate }),
    [api, stores, connection, cache, escalate],
  );

  const started = useRef(false);

  useEffect(() => {
    if (state.kind !== "ready" || started.current) return;
    started.current = true;

    // Identity is known (the bootstrap named the user), so the socket may open.
    connection.connect();

    let live = true;
    void api.get<SessionData>("/session").then((result) => {
      if (!live) return;
      if (result.ok) {
        stores.domain.set((domain) => ({ ...domain, user: result.data.user }));
        setSessionNote(null);
        // The session belongs to somebody else — a re-login in another tab,
        // say. Their cache is not ours to read: the old one goes before this
        // one is opened (spec §12).
        if (result.data.user.id !== cache.userId()) void cache.switchTo(result.data.user.id);
        return;
      }
      const next = stateForErrorCode(result.error.code, result.error.message);
      // A failed session check is not a reason to tear the app down: the
      // bootstrap already told us who we are. It is a reason to say so, though —
      // silently carrying on would be the client knowing something the user
      // doesn't. Task 7 replaces this line with the real connection summary.
      if (next !== null && next.kind !== "start-failed") setState(next);
      else setSessionNote("Couldn’t reach the server to confirm your session.");
    });

    return () => {
      live = false;
    };
  }, [api, cache, connection, stores, state.kind]);

  if (state.kind === "signed-out") {
    return (
      <Screen title="Signed out">
        <p>Your session has ended. Sign in again to pick up where you left off.</p>
        <a
          id="client-sign-in"
          className={`${PRIMARY} mt-5`}
          href={loginPath(window.location.pathname)}
        >
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
    <ServicesProvider value={services}>
      <RouterProvider stores={stores} scrollContainer={scrollContainer}>
        <div className="flex h-dvh flex-col">
          <Header stores={stores} />
          <StorageNote stores={stores} />
          {sessionNote !== null && (
            <p
              id="client-session-note"
              role="status"
              className="shrink-0 border-b border-amber-300 bg-amber-50 px-4 py-2 text-xs text-amber-900 dark:border-amber-700/60 dark:bg-amber-950/40 dark:text-amber-100"
            >
              {sessionNote}
            </p>
          )}
          <main
            id="client-main"
            ref={mainRef}
            className="flex-1 overflow-y-auto p-6 text-zinc-700 dark:text-zinc-300"
          >
            <RouteView />
          </main>
        </div>
      </RouterProvider>
    </ServicesProvider>
  );
}
