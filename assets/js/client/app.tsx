// The client shell (m04.01 worklists 2–4).
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
//
// This module owns the whole-app STATES (signed out, forbidden, failed to
// start) and the services behind them. The frame — header, nav, rail, main,
// pane — is `frame/app_frame.tsx`, rendered once outside the route switch.
import type { ReactNode } from "react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import type { Bootstrap, ClientState } from "./boot.ts";
import { identityMismatch, initialState, loginPath, stateForErrorCode } from "./boot.ts";
import type { ApiError, SessionData } from "./api/client.ts";
import { createApiClient } from "./api/client.ts";
import { getConnection, initConnection } from "./live/connection.ts";
import { applyDiff, applyState } from "./live/presence_model.ts";
import { browserNetwork } from "./live/network.ts";
import { phoenixTransport } from "./live/phoenix_transport.ts";
import { browserVisibility, createReachabilityProbe } from "./live/reachability.ts";
import { createInitiativeSync } from "./live/refresh.ts";
import { AppFrame } from "./frame/app_frame.tsx";
import { matchRoute } from "./router/route.ts";
import { RouterProvider } from "./router/router.tsx";
import { RouteView } from "./screens/route_view.tsx";
import { createStores } from "./state/stores.ts";
import {
  pendingWriteFrom,
  setConnectionStatus,
  setFatalError,
  setPendingWrites,
  setSnapshotMeta,
  setStorageHealth,
} from "./state/recovery.ts";
import { rowPreferencesFrom, setIndexSort, setRowPreferences } from "./state/preferences.ts";
import { indexSortFrom } from "./screens/initiatives_model.ts";
import { fatalMessage } from "./state/fatal.ts";
import { updateNotifications, updatePresence } from "./state/domain.ts";
import { prepend } from "./state/notifications.ts";
import { pushNotice } from "./state/ui.ts";
import type { Stores } from "./state/stores.ts";
import { ServicesProvider } from "./services.tsx";
import { ConnectionSummary } from "./ui/connection_summary.tsx";
import { Notices } from "./ui/notices.tsx";
import { openClientCache } from "./storage/client_cache.ts";
import { browserIdb } from "./storage/idb.ts";
import { browserKeyValueStore } from "./storage/last_user.ts";
import { browserThemeEnv, currentPreference } from "./lib/theme.ts";
import { browserTouchEnv, currentTouch } from "./lib/touch.ts";

const CARD =
  "max-w-md w-full rounded-xl border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-6 shadow-sm";
const PRIMARY =
  "inline-flex items-center rounded-lg bg-zinc-900 px-3 py-2 text-sm font-medium text-white transition-colors hover:bg-zinc-700 dark:bg-zinc-100 dark:text-zinc-900 dark:hover:bg-white";

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

  // Built once. `useState`'s initialiser, not `useMemo`, because these must not
  // be rebuilt even if React decides to discard a memo.
  const [stores] = useState<Stores>(() =>
    createStores({
      domain: { user: bootstrap.user },
      preferences: {
        theme: currentPreference(browserThemeEnv()),
        touch: currentTouch(browserTouchEnv()),
      },
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
      // What this device has queued and not yet settled, as it changes — and
      // once on open, because unsent work outlives the tab and the count in
      // the summary (and the warning before Sign out throws it away) has to
      // be read back off the device, not assumed to be zero (spec §7).
      onPending: (records) => setPendingWrites(stores.recovery, records.map(pendingWriteFrom)),
    }),
  );
  // The tab's one live connection. A route change must never recreate it — and
  // it opens no socket until the effect below says we have an identity, so a
  // signed-out tab never hammers a handshake it cannot pass.
  // One unit: a re-read in flight when access is taken away must not land
  // after the forget and put the tree back. Screens reach it through the
  // services too: every tree — the snapshot, the deltas, the screen's own
  // writes — goes through its sessions (m04.03 1.4), and the index
  // revalidates behind its list (item 4.6).
  const [sync] = useState(() =>
    createInitiativeSync({
      api,
      domain: stores.domain,
      ui: stores.ui,
      snapshots: cache,
      onForbidden: () => setState({ kind: "forbidden" }),
      // The channel is the connection's, built just below; a screen reaches
      // these long after both exist. The sync joins before it reads (m04.03 3.1).
      channel: {
        subscribe: (id) => getConnection().subscribeInitiative(id),
        unsubscribe: (id) => getConnection().unsubscribeInitiative(id),
      },
    }),
  );
  // The way back from offline that is not the user's click (m04.03 5.2.3):
  // a small read now and then, and the connection's own Retry when it lands.
  // The session read is the cheapest authenticated one there is, and a `401`
  // from it is the same "your session ended" the rest of the client escalates.
  const escalateRef = useRef<((error: ApiError) => boolean) | null>(null);
  const [probe] = useState(() =>
    createReachabilityProbe({
      probe: () =>
        api.get<SessionData>("/session").then((result) => {
          if (!result.ok && result.error.code !== "network") escalateRef.current?.(result.error);
          return result.ok;
        }),
      onReachable: () => getConnection().retry(),
      timers: {
        setTimeout: (callback, ms) => window.setTimeout(callback, ms),
        clearTimeout: (handle) => window.clearTimeout(handle as number),
      },
      network: browserNetwork(),
      visibility: browserVisibility(),
    }),
  );
  const [connection] = useState(() => {
    return initConnection({
      transport: (options) => phoenixTransport(options, () => api.csrfToken()),
      onStatus: (status) => {
        setConnectionStatus(stores.recovery, status);
        probe.setStatus(status);
      },
      onDelta: sync.onDelta,
      // Every join reply — the first, and each rejoin after a drop — says where
      // the server stands; a session behind it re-reads at once (m04.03 3.3).
      onJoined: sync.onJoined,
      onAccessRevoked: sync.onAccessRevoked,
      // Who else is on the Initiative and what they have selected. Filed as
      // the server sends it; the tree reads its badges and dots from here.
      onPresence: (initiativeId, event) =>
        updatePresence(stores.domain, initiativeId, (state) =>
          event.kind === "state" ? applyState(state, event.payload) : applyDiff(state, event.payload),
        ),
      // What happened to YOU, wherever you are in the client: the row arrives
      // ready to render, so the bell only has to put it on top.
      onNotification: (row) => updateNotifications(stores.domain, (state) => prepend(state, row)),
    });
  });

  // The frame's scrolling region, handed to the router so back/forward can put
  // the user back where they were. It is the frame's, not a screen's: a route
  // change must not swap the element the scroll memory is keyed to.
  const scrollRef = useRef<HTMLElement | null>(null);
  const scrollContainer = useCallback(() => scrollRef.current, []);

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

  escalateRef.current = escalate;

  const services = useMemo(
    () => ({ api, stores, connection, sync, cache, escalate }),
    [api, stores, connection, sync, cache, escalate],
  );

  // Failures that escape everything else, once the client is up — but only the
  // ones the client itself marked unrecoverable (`markFatal`). Not every stray
  // rejection: this client hands off plenty of fire-and-forget work, most of it
  // to IndexedDB, and one refused write is a storage-health matter that belongs
  // on the secondary storage line, not a reason to replace the connection state
  // with "Do It List hit a problem". A cross-origin script error, which arrives
  // with no error object at all, is no reason either. When it IS fatal the
  // summary says so and offers Reload, and the content on screen stays readable
  // meanwhile (spec §7).
  useEffect(() => {
    const report = (error: unknown) => {
      if (window.__doit_client_ready !== true) return;
      const message = fatalMessage(error);
      if (message !== null) setFatalError(stores.recovery, message);
    };
    const onError = (event: ErrorEvent) => report(event.error);
    const onRejection = (event: PromiseRejectionEvent) => report(event.reason);

    window.addEventListener("error", onError);
    window.addEventListener("unhandledrejection", onRejection);
    return () => {
      window.removeEventListener("error", onError);
      window.removeEventListener("unhandledrejection", onRejection);
    };
  }, [stores.recovery]);

  const started = useRef(false);

  // Is this component still on screen? Kept apart from the startup effect
  // below on purpose. That effect runs its work ONCE (`started`), but React
  // in development mounts, unmounts and mounts again — so its own cleanup
  // would cancel the work the first mount started and the second mount would
  // never redo it. This one re-arms on every mount, so what is in flight is
  // only dropped when the component really goes away.
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  useEffect(() => {
    if (state.kind !== "ready" || started.current) return;
    started.current = true;

    // Identity is known (the bootstrap named the user), so the socket may open,
    // and the user's own channel with it — it is the tab's, not a screen's.
    connection.connect();
    if (bootstrap.user !== null) connection.watchUser(bootstrap.user.id);

    void api.get<SessionData>("/session").then((result) => {
      if (!alive.current) return;
      if (result.ok) {
        stores.domain.set((domain) => ({ ...domain, user: result.data.user }));
        // The account's row-display choices, read once. The tree draws its rows
        // from these, so they arrive before any tree does.
        setRowPreferences(stores.preferences, rowPreferencesFrom(result.data.preferences));
        // The index's saved sort, so the list opens in the order the account
        // keeps (7.3). The screen writes changes back through `update account`.
        setIndexSort(stores.preferences, indexSortFrom(result.data.preferences));
        // The session belongs to somebody else — a re-login in another tab,
        // say. Their cache is not ours to read: the old one goes before this
        // one is opened (spec §12).
        if (result.data.user.id !== cache.userId()) void cache.switchTo(result.data.user.id);
        // The socket and the user channel were opened as the page's user; a
        // different one now means nothing this tab does is safe (m04.03 5.1.2).
        const mismatch = identityMismatch(bootstrap.user, result.data.user);
        if (mismatch !== null) setFatalError(stores.recovery, mismatch);
        return;
      }
      const next = stateForErrorCode(result.error.code, result.error.message);
      // A failed session check is not a reason to tear the app down: the
      // bootstrap already told us who we are. It is a reason to say so, though —
      // silently carrying on would be the client knowing something the user
      // doesn't.
      if (next !== null && next.kind !== "start-failed") setState(next);
      else {
        pushNotice(stores.ui, {
          kind: "info",
          message: "Couldn’t reach the server to confirm your session.",
        });
      }
    });
  }, [api, bootstrap.user, cache, connection, stores, state.kind]);

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
        <AppFrame stores={stores} scrollRef={scrollRef} summary={<ConnectionSummary />}>
          <RouteView />
        </AppFrame>
        <Notices />
      </RouterProvider>
    </ServicesProvider>
  );
}
