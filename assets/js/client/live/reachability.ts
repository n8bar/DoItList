// The low-frequency reachability probe (m04.03 5.2.3, spec §5).
//
// Once the client has stopped retrying on its own (`offline`), the socket is
// down for good until somebody says otherwise. Usually that is the user's
// Retry; this is the other way back. While the tab is offline and the browser
// itself says it has a network, one small authenticated read goes out now and
// then — 15 s at first, doubling to a two-minute ceiling, jittered ±25 % so
// every tab a server left behind does not knock at the same second. A read
// that lands calls `onReachable` ONCE, which is the same path as the user's
// Retry: the socket re-opens, the joins resync, the queue replays. No visible
// reconnect loop, because nothing here touches the connection state — a
// failed probe simply books the next one.
//
// It never probes a hidden tab (a background tab has no user to serve and
// forty of them would be a slow DDoS of the server that just came back), and
// it never probes while the browser says the machine has no network at all.
// Both signals are injected, like the timers and the die, so every schedule
// below is asserted rather than sampled.

import type { ConnectionStatus } from "../state/recovery.ts";
import type { Timers } from "./connection.ts";
import type { NetworkSignal } from "./network.ts";

/** The first probe after the client goes offline. */
export const PROBE_START_MS = 15_000;
/** The probes never come slower than this. */
export const PROBE_CAP_MS = 120_000;
/** How far either side of the scheduled delay the jitter may land. */
export const PROBE_JITTER_RATIO = 0.25;

/**
 * The delay before probe number `attempt` (1-based): doubling from the start
 * to the cap, jittered. Jitter spreads a delay; it never extends the cap.
 */
export function probeDelayMs(attempt: number, random: () => number = Math.random): number {
  const step = Math.max(1, Math.trunc(attempt)) - 1;
  const base = Math.min(PROBE_CAP_MS, PROBE_START_MS * 2 ** step);
  const spread = (random() * 2 - 1) * PROBE_JITTER_RATIO;
  return Math.min(PROBE_CAP_MS, Math.max(1, Math.round(base * (1 + spread))));
}

/** "Is this tab on screen?" Injected in tests; the document by default. */
export interface VisibilitySignal {
  hidden(): boolean;
  /** Calls back on every change. Returns the unsubscribe. */
  subscribe(onChange: (hidden: boolean) => void): () => void;
}

/** Always visible, for a runtime with no document (tests, SSR). */
export const ALWAYS_VISIBLE: VisibilitySignal = {
  hidden: () => false,
  subscribe: () => () => {},
};

export function browserVisibility(): VisibilitySignal {
  if (typeof document === "undefined") return ALWAYS_VISIBLE;
  return {
    hidden: () => document.visibilityState === "hidden",
    subscribe(onChange) {
      const listener = () => onChange(document.visibilityState === "hidden");
      document.addEventListener("visibilitychange", listener);
      return () => document.removeEventListener("visibilitychange", listener);
    },
  };
}

export interface ReachabilityDeps {
  /** One small authenticated read. Resolves `true` when the server answered. Never rejects. */
  probe(): Promise<boolean>;
  /** The server is back: the caller re-opens the connection (`connection.retry()`). */
  onReachable(): void;
  timers: Timers;
  network: NetworkSignal;
  visibility?: VisibilitySignal;
  random?: () => number;
}

export interface ReachabilityProbe {
  /** Feed every connection status change; the probe runs only while `offline`. */
  setStatus(status: ConnectionStatus): void;
  /** Tab teardown: nothing more goes out. */
  stop(): void;
}

export function createReachabilityProbe(deps: ReachabilityDeps): ReachabilityProbe {
  const visibility = deps.visibility ?? ALWAYS_VISIBLE;
  let status: ConnectionStatus = "connecting";
  let attempt = 0;
  let handle: unknown = null;
  let inFlight = false;
  let stopped = false;

  const cancel = () => {
    if (handle !== null) deps.timers.clearTimeout(handle);
    handle = null;
  };

  // Should a probe be on the books right now? Offline, on screen, with a
  // network the browser believes in, and none already booked or out.
  const wanted = () =>
    !stopped && status === "offline" && !visibility.hidden() && deps.network.online() && handle === null && !inFlight;

  const schedule = () => {
    if (!wanted()) return;
    attempt += 1;
    handle = deps.timers.setTimeout(fire, probeDelayMs(attempt, deps.random));
  };

  const fire = () => {
    handle = null;
    // The world may have moved while the timer ran: hidden, back online, torn down.
    if (stopped || status !== "offline" || visibility.hidden() || !deps.network.online()) return;
    inFlight = true;
    void deps.probe().then((reachable) => {
      inFlight = false;
      if (stopped || status !== "offline") return;
      if (reachable) {
        // Once. `setStatus` moves us off `offline` as the connection re-opens;
        // if it never does (the retry was refused), the next status feed
        // decides whether to book again — not this callback.
        attempt = 0;
        deps.onReachable();
        return;
      }
      schedule();
    });
  };

  const unwatchVisibility = visibility.subscribe((hidden) => {
    if (hidden) cancel();
    else schedule();
  });
  const unwatchNetwork = deps.network.subscribe((online) => {
    if (!online) cancel();
    else schedule();
  });

  return {
    setStatus(next) {
      if (next === status) return;
      status = next;
      if (next === "offline") {
        attempt = 0;
        schedule();
      } else {
        cancel();
      }
    },
    stop() {
      stopped = true;
      cancel();
      unwatchVisibility();
      unwatchNetwork();
    },
  };
}
