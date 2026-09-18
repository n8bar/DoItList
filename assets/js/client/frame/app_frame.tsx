// The application frame (m04.01 items 4.1, 4.4, 4.6).
//
// Rendered ONCE, outside the route switch, so the header and the nav are the
// same DOM on every route: a navigation replaces the contents of
// `<main>` and touches nothing else. That is not a performance nicety, it is
// the no-layout-shift rule (item 4.6) — chrome that is re-created per route is
// chrome that can come back a pixel different.
//
// It is the LiveView layout's frame, not a redesign: the same container caps
// (`Layouts.app`'s `:wide`), the same header band, the same zinc/emerald
// palette and the same `dark:` story, so `/app` and the LiveView pages read as
// one product until the cutover (spec §2).
//
// Regions, and who owns them:
//   header      — wordmark, primary nav, theme, bell, account menu, narrow
//                 menu (here)
//   main        — the route outlet, with the `<h1>` focus contract (Task 4)
//   pane        — right-hand slot routes fill; Arc 2's Details pane (pane.tsx).
//                 From `lg:` it is the workspace's right column; below `lg:`
//                 it is the workspace's `#details-rail` flyout over a backdrop,
//                 with its own Close (m04.02 item 2.3)
//   summary     — the connection summary (ui/connection_summary.tsx), in the
//                 header band where the LiveView's connecting signifier sits.
//                 It is positioned OUT OF FLOW, so it can change from "Live" to
//                 "Offline — 3 changes waiting" without moving anything (4.6).

import type { ReactNode, RefObject } from "react";
import { useCallback, useMemo, useState } from "react";

import { Link } from "../router/link.tsx";
import type { DomainState } from "../state/domain.ts";
import { useStoreValue } from "../state/use_store.ts";
import { AccountMenu } from "./account_menu.tsx";
import { Bell } from "./bell.tsx";
import { HOME_PATH } from "../router/route.ts";
import { useRoute } from "../router/router.tsx";
import type { Stores } from "../state/stores.ts";
import { NavMenu } from "./menu.tsx";
import { NAV_ITEMS, isCurrentNav } from "./nav_model.ts";
import { NavButton } from "./nav_button.tsx";
import type { PaneControl } from "./pane.tsx";
import { PaneProvider } from "./pane.tsx";
import { Icon } from "../ui/icon.tsx";
import type { CloseTenant, Tenants } from "./pane_slot.ts";
import { NO_TENANTS, addTenant, closeTenants, paneOpenMarker, paneVisible, removeTenant } from "./pane_slot.ts";
import { ThemeToggle } from "./theme_toggle.tsx";
import { TouchSwitch } from "./touch_switch.tsx";

/**
 * `Layouts.app`'s `:wide` cap, verbatim: the header mirrors the body so the two
 * stay aligned at every width.
 */
const CONTAINER = "mx-auto w-full max-w-6xl xl:max-w-7xl 2xl:max-w-[90rem] 3xl:max-w-[140rem]";

export interface AppFrameProps {
  stores: Stores;
  /** The scrolling region. The router remembers and restores its position. */
  scrollRef: RefObject<HTMLElement | null>;
  /**
   * The connection summary. Rendered inside the header's positioning context
   * and out of flow, so its six states cannot resize the header band.
   */
  summary?: ReactNode;
  children: ReactNode;
}

const selectUser = (state: DomainState) => state.user;

export function AppFrame({ stores, scrollRef, summary, children }: AppFrameProps) {
  const route = useRoute();
  // The header draws the signed-in user (the avatar). It comes from the domain
  // store, not a prop: the session read fills it in a moment after boot.
  const user = useStoreValue(stores.domain, selectUser);
  // Which routes are filling the pane (each by the closer it left), and the
  // element they portal into. The frame learns nothing about WHAT is in the
  // pane, so a tenant re-rendering its own content never re-renders the frame
  // (see `pane.tsx`).
  const [paneTenants, setPaneTenants] = useState<Tenants>(NO_TENANTS);
  const [paneHost, setPaneHost] = useState<HTMLElement | null>(null);

  const acquirePane = useCallback((close: CloseTenant) => {
    setPaneTenants((tenants) => addTenant(tenants, close));
    let released = false;
    return () => {
      if (released) return;
      released = true;
      setPaneTenants((tenants) => removeTenant(tenants, close));
    };
  }, []);
  // The flyout's Close: the rail's X and the backdrop, below `lg:`. The
  // workspace's `[data-close-panel]` clears the selection; here the tenant
  // decides what closing means.
  const closePane = useCallback(() => closeTenants(paneTenants), [paneTenants]);
  const paneControl = useMemo<PaneControl>(
    () => ({ acquire: acquirePane, host: paneHost }),
    [acquirePane, paneHost],
  );
  const hasPane = paneVisible(paneTenants);

  // The pane's column only exists when a tenant does — an empty slot is no
  // slot, not an empty gutter. There is no left rail: the LiveView page has
  // none below ultrawide, and a column repeating the header's nav was a
  // scaffold, not the product (item 6.8).
  // The column starts at `lg:`, where the workspace's does; below it the pane
  // is the flyout, never a block under the tree (item 2.3).
  const grid = hasPane ? "lg:grid lg:grid-cols-[minmax(0,1fr)_24rem] lg:items-start lg:gap-6" : "";

  return (
    <PaneProvider value={paneControl}>
      <div className="relative flex h-dvh flex-col bg-white text-zinc-900 dark:bg-zinc-950 dark:text-zinc-100">
        <a
          id="client-skip-link"
          href="#client-main"
          className="sr-only focus:not-sr-only focus:absolute focus:left-4 focus:top-3 focus:z-50 focus:rounded-lg focus:border focus:border-emerald-600 focus:bg-white focus:px-3 focus:py-2 focus:text-sm focus:font-medium focus:text-emerald-900 dark:focus:bg-zinc-900 dark:focus:text-emerald-100"
        >
          Skip to content
        </a>

        <header
          id="client-header"
          className="flex-none border-b border-zinc-300 bg-white dark:border-zinc-700 dark:bg-zinc-900"
        >
          <div className={`${CONTAINER} flex items-center justify-between gap-3 px-4 py-3 sm:px-6`}>
            <Link
              id="client-wordmark"
              to={HOME_PATH}
              className="flex min-h-11 flex-none items-center gap-2 rounded-lg px-1 font-semibold text-zinc-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 dark:text-zinc-100 dark:focus-visible:ring-emerald-400 sm:min-h-9"
            >
              <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm bg-emerald-500" />
              Do It List
            </Link>

            {/* The summary's own slot. Below `md:` this wrapper is not a box
                at all (`display: contents`) — `justify-between` keeps the
                controls on the right edge and the badge floats bottom-left —
                and from `md:` up it is a flex item between the wordmark and
                the controls, so the three share the band by measurement rather
                than by luck. The quiet "Live" fits that slot from `md:`; the
                loud states (Retry, Reload) only move in from `lg:`, where the
                slot is wide enough that nothing can cover Retry and Retry
                cannot cover the nav (see `ConnectionSummary`).

                The slot has a FIXED height and the badge floats inside it: the
                summary has six states and a second line it can grow, and none
                of them may make the header taller (item 4.6). */}
            <div className="contents md:relative md:block md:h-9 md:min-w-0 md:flex-1 md:px-3">
              {summary}
            </div>

            {/* Nav and controls are ONE right-hand group, as the LiveView
                header has them. */}
            <div className="flex flex-none items-center gap-2">
              <nav id="client-nav" aria-label="Primary" className="hidden items-center gap-2 sm:flex">
                {NAV_ITEMS.map((item) => (
                  <NavButton
                    key={item.key}
                    id={`client-nav-${item.key}`}
                    to={item.to}
                    label={item.label}
                    current={isCurrentNav(route, item.key)}
                  />
                ))}
              </nav>

              <span
                aria-hidden="true"
                className="hidden h-5 w-px flex-none bg-zinc-300 dark:bg-zinc-700 sm:block"
              />

              {/* Wrapped, not classed: the group's own `inline-flex` outranks a
                  `hidden` on the same element, so the breakpoint lives on a
                  wrapper that is no box at all above it. */}
              <div className="hidden sm:contents">
                <ThemeToggle stores={stores} />
                <TouchSwitch stores={stores} />
              </div>
              {/* The bell is a top-level item at EVERY breakpoint — never
                  folded into the hamburger — exactly as the LiveView header
                  has it, so notifications are one tap away on a phone too. */}
              <Bell />
              {user === null ? null : <AccountMenu user={user} className="hidden sm:block" />}
              <NavMenu stores={stores} route={route} user={user} />
            </div>
          </div>
        </header>

        {/* The one scrolling region. `scrollbar-gutter: stable` keeps the content
            from sliding sideways when a long route brings a scrollbar with it. */}
        <div
          id="client-scroll"
          ref={scrollRef as RefObject<HTMLDivElement | null>}
          className="min-h-0 flex-1 overflow-y-auto [scrollbar-gutter:stable]"
        >
          <div className={`${CONTAINER} px-4 py-8 sm:px-6`}>
            <div className={grid}>
              <main id="client-main" tabIndex={-1} className="min-w-0 outline-none">
                {children}
              </main>

              {/* Backdrop on mobile when the right-rail flyout is open — the
                  workspace's `#pane-backdrop`. It exists only while the pane
                  does, which is the workspace's `hidden` flip. */}
              {hasPane && (
                <div
                  id="pane-backdrop"
                  className="lg:hidden fixed inset-0 z-20 bg-black/50"
                  data-close-panel
                  aria-hidden="true"
                  onClick={closePane}
                />
              )}

              {/* The right pane — the workspace's `#details-rail` (item 2.3.1).
                  From `lg:` it is the column, sticky in the one scrolling
                  region as the frame has always kept it. Below `lg:` the
                  `data-open` variants make it a fixed overlay over the
                  backdrop, with the rail's own Close at the top; the Details
                  pane's desktop X is `lg:`-only, as the workspace's is. */}
              {hasPane && (
                <aside
                  id="details-rail"
                  data-open={paneOpenMarker(paneTenants)}
                  aria-label="Details"
                  className={[
                    "not-data-open:hidden lg:not-data-open:block",
                    "data-open:block data-open:fixed lg:data-open:sticky data-open:top-0 lg:data-open:top-8 data-open:bottom-0 lg:data-open:bottom-auto data-open:right-0 lg:data-open:right-auto data-open:z-30 lg:data-open:z-auto",
                    "data-open:w-full sm:data-open:w-96 lg:data-open:w-auto",
                    "data-open:bg-zinc-50 lg:data-open:bg-transparent dark:data-open:bg-zinc-950 lg:dark:data-open:bg-transparent",
                    "data-open:shadow-xl lg:data-open:shadow-none data-open:p-4 lg:data-open:p-0",
                    "data-open:overflow-y-auto lg:data-open:overflow-visible data-open:[scrollbar-gutter:stable] lg:data-open:[scrollbar-gutter:auto]",
                    "space-y-4 lg:space-y-0 lg:self-start",
                  ].join(" ")}
                >
                  <div className="lg:hidden flex justify-end">
                    <button
                      type="button"
                      data-close-panel
                      aria-label="Close details panel"
                      title="Close"
                      onClick={closePane}
                      className="inline-flex items-center justify-center w-8 h-8 rounded bg-red-500/30 hover:bg-red-500/50 text-white font-bold"
                    >
                      <Icon name="x-mark" className="w-5 h-5" />
                    </button>
                  </div>
                  <div ref={setPaneHost} />
                </aside>
              )}
            </div>
          </div>
        </div>
      </div>
    </PaneProvider>
  );
}
