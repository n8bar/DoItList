// The client router (m04.01 items 3.2–3.3, 3.7).
//
// A route change is a local state change, never a request: the new screen is on
// the glass before anything is fetched, and the fetch (if any) fills in under a
// visible loading state (spec §2, guardrails §6). Deep links and refresh work
// because `matchRoute(location.pathname)` is the *only* thing that decides what
// renders — a direct load, a `<Link>` click and a back button all go through it.
//
// The `ClientHistory` and the live connection are module-level: they belong to
// the tab, not to a component, so remounting a screen can't reset either
// (guardrail §7.4).

import type { ReactNode } from "react";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";

import type { RestorationPlan } from "../lib/navigation.ts";
import {
  RESTORE_TIMEOUT_MS,
  beginRestore,
  focusTarget,
  restorationPlan,
  restoreStep,
} from "../lib/navigation.ts";
import type { Stores } from "../state/stores.ts";
import { rememberPlace, setRoute } from "../state/ui.ts";
import type { ClientHistory, HistoryEntry } from "./history.ts";
import { browserHistoryEnv, createClientHistory } from "./history.ts";
import type { Route } from "./route.ts";
import { matchRoute, sameRoute } from "./route.ts";

/** The id every route's `<h1>` carries, and the default focus landing spot. */
export const ROUTE_HEADING_ID = "route-heading";

export interface NavigateOptions {
  /** Replace the current entry instead of pushing a new one. */
  replace?: boolean;
}

export interface RouterValue {
  readonly route: Route;
  /** The current history entry's key — stable per entry, not per path. */
  readonly historyKey: string;
  navigate(to: string, options?: NavigateOptions): void;
}

const RouterContext = createContext<RouterValue | null>(null);

export function useRouter(): RouterValue {
  const value = useContext(RouterContext);
  if (value === null) throw new Error("useRouter was called outside a <RouterProvider>.");
  return value;
}

/** The current route, for components that only read it. */
export function useRoute(): Route {
  return useRouter().route;
}

// One history adapter per tab. Created lazily (so importing this module in a
// test runner doesn't touch `window`) and never disposed — the tab's history is
// not a component's to own.
let sharedHistory: ClientHistory | null = null;

function tabHistory(): ClientHistory {
  if (sharedHistory === null) sharedHistory = createClientHistory(browserHistoryEnv());
  return sharedHistory;
}

/** The id of the element that has focus, or `null` if it isn't identifiable. */
function activeElementId(): string | null {
  const active = document.activeElement;
  if (!(active instanceof HTMLElement)) return null;
  return active.id === "" ? null : active.id;
}

/** Moves focus to the remembered element, or to the route's heading. */
function applyFocus(plan: RestorationPlan): void {
  const target = focusTarget(plan, (id) => document.getElementById(id) !== null);
  const id = target.kind === "element" ? target.id : ROUTE_HEADING_ID;
  // The scroll we just set (or are still working towards) is the intended one;
  // focusing must not undo it.
  document.getElementById(id)?.focus({ preventScroll: true });
}

/**
 * Drives `restoreStep` against a real container: once now, and again whenever
 * the content changes, until the position is reached, the attempts run out, the
 * watch times out, or the user scrolls. Returns the teardown.
 */
function restoreScroll(container: HTMLElement, target: number): () => void {
  let state = beginRestore(target);
  let observer: MutationObserver | null = null;
  let timer: number | undefined;

  const stop = () => {
    observer?.disconnect();
    observer = null;
    if (timer !== undefined) window.clearTimeout(timer);
    timer = undefined;
  };

  const attempt = () => {
    const step = restoreStep(state, {
      scrollTop: container.scrollTop,
      scrollHeight: container.scrollHeight,
      clientHeight: container.clientHeight,
    });
    state = step.state;
    if (step.apply !== null) container.scrollTop = step.apply;
    if (step.finished) stop();
  };

  attempt();

  // Not there yet: the route is still fetching what gives the page its height.
  // A DOM change in the container is the signal to try again — setting
  // `scrollTop` mutates nothing, so this cannot feed itself.
  if (!state.finished && typeof MutationObserver !== "undefined") {
    observer = new MutationObserver(attempt);
    observer.observe(container, { childList: true, subtree: true, characterData: true });
    timer = window.setTimeout(stop, RESTORE_TIMEOUT_MS);
  }

  return stop;
}

export interface RouterProviderProps {
  stores: Stores;
  /** The element whose `scrollTop` is remembered and restored. */
  scrollContainer: () => HTMLElement | null;
  children: ReactNode;
}

export function RouterProvider({ stores, scrollContainer, children }: RouterProviderProps) {
  const history = tabHistory();
  const [entry, setEntry] = useState<HistoryEntry>(() => history.current());
  const leaving = useRef<string>(entry.key);

  const route = useMemo(() => matchRoute(entry.path), [entry.path]);

  // Remembers where the user was on the entry they are leaving. Called before a
  // push, and at the top of a popstate — in both cases the old screen is still
  // on the glass, so these are the numbers the user will expect back.
  const rememberCurrent = useCallback(() => {
    rememberPlace(stores.ui, leaving.current, {
      scrollTop: scrollContainer()?.scrollTop ?? 0,
      focusElementId: activeElementId(),
    });
  }, [scrollContainer, stores.ui]);

  useEffect(() => {
    return history.listen((next) => {
      if (next.kind === "pop") rememberCurrent();
      leaving.current = next.key;
      setEntry(next);
    });
  }, [history, rememberCurrent]);

  const navigate = useCallback(
    (to: string, options?: NavigateOptions) => {
      const current = history.current();
      // "Already here" is a question about routes, not strings: `/app/account`
      // and `/app/account/` are the same screen and must not stack an entry.
      if (options?.replace !== true && sameRoute(matchRoute(to), matchRoute(current.path))) return;
      rememberCurrent();
      if (options?.replace === true) history.replace(to);
      else history.push(to);
    },
    [history, rememberCurrent],
  );

  // `/app` itself renders nothing; it becomes `/app/initiatives` without
  // leaving an entry behind, so back from the Initiatives list leaves the app
  // rather than bouncing off the redirect.
  useEffect(() => {
    if (route.kind === "redirect") navigate(route.to, { replace: true });
  }, [route, navigate]);

  // The route is ephemeral view state, so it lives in the `ui` store, and the
  // router is its only writer.
  useEffect(() => {
    setRoute(stores.ui, route);
  }, [route, stores.ui]);

  // Scroll and focus, after the new screen has rendered. A layout effect, so
  // the user never sees the new route at the old scroll position first.
  useLayoutEffect(() => {
    if (route.kind === "redirect") return;

    const plan = restorationPlan(entry.kind, entry.key, stores.ui.get().navigationMemory);
    const container = scrollContainer();

    // A first paint is not a navigation: the browser has just given the page
    // focus and moving it would be the client taking something the user didn't
    // ask for.
    if (entry.kind !== "initial") applyFocus(plan);

    if (!container) {
      window.scrollTo(0, plan.scrollTop);
      return;
    }

    return restoreScroll(container, plan.scrollTop);
  }, [entry.key, entry.kind, route.kind, scrollContainer, stores.ui]);

  const value = useMemo<RouterValue>(
    () => ({ route, historyKey: entry.key, navigate }),
    [route, entry.key, navigate],
  );

  return <RouterContext.Provider value={value}>{children}</RouterContext.Provider>;
}
