// "Is there a network at all?" (m04.01 items 4.2-4.3, spec §7).
//
// The socket finds out a link is gone by not being answered, which takes as
// long as the heartbeat takes — up to a minute of a badge cheerfully reading
// "Live" while nothing works. The browser knows sooner: it fires `offline` the
// moment the machine loses its network. Taking that signal is the difference
// between the summary telling the truth and the summary being the last to know.
//
// `online` is deliberately NOT a resume. Coming back from offline is one rule
// in this client, whatever stopped it: the user asks (`connection.retry()`).

export interface NetworkSignal {
  /** The browser's current answer. */
  online(): boolean;
  /** Calls back on every change. Returns the unsubscribe. */
  subscribe(onChange: (online: boolean) => void): () => void;
}

interface EventTargetLike {
  addEventListener(type: string, listener: () => void): void;
  removeEventListener(type: string, listener: () => void): void;
}

/**
 * The signal over a real window. Injected in tests; `browserNetwork()` is what
 * the app uses.
 */
export function createNetworkSignal(
  target: EventTargetLike,
  isOnline: () => boolean,
): NetworkSignal {
  return {
    online: isOnline,
    subscribe(onChange) {
      const onOnline = () => onChange(true);
      const onOffline = () => onChange(false);
      target.addEventListener("online", onOnline);
      target.addEventListener("offline", onOffline);
      return () => {
        target.removeEventListener("online", onOnline);
        target.removeEventListener("offline", onOffline);
      };
    },
  };
}

/** Always-online, for a runtime with no window (tests, SSR). */
export const ALWAYS_ONLINE: NetworkSignal = {
  online: () => true,
  subscribe: () => () => {},
};

export function browserNetwork(): NetworkSignal {
  if (typeof window === "undefined") return ALWAYS_ONLINE;
  // Some runtimes have no `onLine`; "we don't know" must read as online, or a
  // working client would sit there claiming to be offline.
  const isOnline = () => window.navigator?.onLine !== false;
  return createNetworkSignal(window, isOnline);
}
