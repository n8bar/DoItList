// The application frame (m04.01 items 4.1, 4.4, 4.6).
//
// Rendered ONCE, outside the route switch, so the header, the nav and the rail
// are the same DOM on every route: a navigation replaces the contents of
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
//   header      — wordmark, primary nav, theme, sign out, narrow menu (here)
//   rail        — the same nav as a desktop column (here)
//   main        — the route outlet, with the `<h1>` focus contract (Task 4)
//   pane        — right-hand slot routes fill; Arc 2's Details pane (pane.tsx)
//   summary     — the connection summary (ui/connection_summary.tsx), in the
//                 header band where the LiveView's connecting signifier sits.
//                 It is positioned OUT OF FLOW, so it can change from "Live" to
//                 "Offline — 3 changes waiting" without moving anything (4.6).

import type { ReactNode, RefObject } from "react";
import { useCallback, useMemo, useState } from "react";

import { Link } from "../router/link.tsx";
import { HOME_PATH } from "../router/route.ts";
import { useRoute } from "../router/router.tsx";
import type { Stores } from "../state/stores.ts";
import { NavMenu } from "./menu.tsx";
import { NAV_ITEMS, isCurrentNav } from "./nav_model.ts";
import { NavButton } from "./nav_button.tsx";
import type { PaneControl } from "./pane.tsx";
import { PaneProvider } from "./pane.tsx";
import { addTenant, paneVisible, removeTenant } from "./pane_slot.ts";
import { SignOut } from "./sign_out.tsx";
import { ThemeToggle } from "./theme_toggle.tsx";

/**
 * `Layouts.app`'s `:wide` cap, verbatim: the header mirrors the body so the two
 * stay aligned at every width, and the 3xl step is what makes the rail *added*
 * width rather than width stolen from the main column.
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

export function AppFrame({ stores, scrollRef, summary, children }: AppFrameProps) {
  const route = useRoute();
  // How many routes are filling the pane, and the element they portal into. The
  // frame learns nothing about WHAT is in the pane, so a tenant re-rendering its
  // own content never re-renders the frame (see `pane.tsx`).
  const [paneTenants, setPaneTenants] = useState(0);
  const [paneHost, setPaneHost] = useState<HTMLElement | null>(null);

  const acquirePane = useCallback(() => {
    setPaneTenants(addTenant);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      setPaneTenants(removeTenant);
    };
  }, []);
  const paneControl = useMemo<PaneControl>(
    () => ({ acquire: acquirePane, host: paneHost }),
    [acquirePane, paneHost],
  );
  const hasPane = paneVisible(paneTenants);

  // The pane's column only exists when a tenant does — an empty slot is no
  // slot, not an empty gutter.
  const grid = [
    "lg:grid lg:items-start lg:gap-6",
    hasPane
      ? "lg:grid-cols-[15rem_minmax(0,1fr)] xl:grid-cols-[15rem_minmax(0,1fr)_24rem]"
      : "lg:grid-cols-[15rem_minmax(0,1fr)]",
  ].join(" ");

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
          {/* `relative`: the connection summary centres itself in this band
              from `lg:` up, exactly as the LiveView signifier does. */}
          <div
            className={`${CONTAINER} relative flex items-center justify-between gap-3 px-4 py-3 sm:px-6`}
          >
            <Link
              id="client-wordmark"
              to={HOME_PATH}
              className="flex min-h-11 flex-none items-center gap-2 rounded-lg px-1 font-semibold text-zinc-800 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600 dark:text-zinc-100 dark:focus-visible:ring-emerald-400 sm:min-h-9"
            >
              <span aria-hidden="true" className="inline-block h-2.5 w-2.5 rounded-sm bg-emerald-500" />
              Do It List
            </Link>

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

            <div className="flex flex-none items-center gap-2">
              <ThemeToggle stores={stores} className="hidden sm:inline-flex" />
              <SignOut idPrefix="client" className="hidden sm:block" />
              <NavMenu stores={stores} route={route} />
            </div>

            {summary}
          </div>
        </header>

        {/* The one scrolling region. `scrollbar-gutter: stable` keeps the rail
            from sliding sideways when a long route brings a scrollbar with it. */}
        <div
          id="client-scroll"
          ref={scrollRef as RefObject<HTMLDivElement | null>}
          className="min-h-0 flex-1 overflow-y-auto [scrollbar-gutter:stable]"
        >
          <div className={`${CONTAINER} px-4 py-8 sm:px-6`}>
            <div className={grid}>
              <aside
                id="client-rail"
                className="hidden lg:sticky lg:top-8 lg:block lg:self-start"
              >
                <h2 className="mb-2 px-2 text-xs font-semibold uppercase tracking-wide text-zinc-400 dark:text-zinc-500">
                  Sections
                </h2>
                <nav aria-label="Sections" className="flex flex-col gap-1">
                  {NAV_ITEMS.map((item) => (
                    <NavButton
                      key={item.key}
                      id={`client-rail-nav-${item.key}`}
                      to={item.to}
                      label={item.label}
                      current={isCurrentNav(route, item.key)}
                      block
                    />
                  ))}
                </nav>
              </aside>

              <main id="client-main" tabIndex={-1} className="min-w-0 outline-none">
                {children}
              </main>

              {hasPane && (
                <aside
                  id="client-pane"
                  ref={setPaneHost}
                  aria-label="Details"
                  className="mt-8 xl:sticky xl:top-8 xl:mt-0 xl:self-start"
                />
              )}
            </div>
          </div>
        </div>
      </div>
    </PaneProvider>
  );
}
