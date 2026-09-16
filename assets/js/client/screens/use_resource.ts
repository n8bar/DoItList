// One screen, one read (m04.01 worklist 3).
//
// The rule this encodes: a fetch never stands between the user and the route.
// The screen renders immediately — heading, chrome and all — and this hook only
// decides what fills the body: a visible loading state, an error the user can
// retry in place, or nothing at all when the store already holds the answer
// (a route revisited within the session does not flash a spinner).

import { useCallback, useEffect, useRef, useState } from "react";

import type { ApiError, Result } from "../api/client.ts";

export type ResourceStatus = "loading" | "ready" | "error";

export interface ResourceOptions<T> {
  /** Identity of what is being read. A change starts a fresh load. */
  key: string;
  /** True when the store already has it: no fetch, no spinner. */
  loaded: boolean;
  read: () => Promise<Result<T>>;
  /** May throw: a read the screen cannot adopt is not an answer. */
  onData: (data: T) => void;
  /**
   * `onData` threw twice running. Return the line to show in place; the screen
   * also raises whatever notice it wants from here.
   */
  onUnusable?: (error: unknown) => string;
  /** See `Services.escalate` — `true` means the shell took the failure over. */
  escalate: (error: ApiError) => boolean;
}

/** When the screen offers no wording of its own. */
export const UNUSABLE_MESSAGE = "This did not arrive in a usable state.";

/** How a single load ended. */
export type Attempt =
  | { outcome: "ready" }
  /** The caller stopped caring (unmounted, or the key changed). */
  | { outcome: "abandoned" }
  | { outcome: "failed"; error: ApiError }
  /** Every read came back, and none of them could be adopted. */
  | { outcome: "unusable"; error: unknown };

/**
 * Read, hand the answer to the screen, and read once more if the screen threw
 * it back — a snapshot that cannot be a tree may be one bad response rather
 * than a broken Initiative. The second refusal is final: the screen shows an
 * error the user can retry, never a spinner that never ends (arc item 1.6.2).
 *
 * Kept free of React so the rule can be tested on its own.
 */
export async function readUsable<T>(options: {
  read: () => Promise<Result<T>>;
  /** May throw to refuse the answer. */
  adopt: (data: T) => void;
  /** False once nobody is waiting for this any more. */
  alive?: () => boolean;
  /** How many extra reads a refusal buys. One, by contract. */
  rereads?: number;
}): Promise<Attempt> {
  const alive = options.alive ?? (() => true);
  let left = options.rereads ?? 1;

  for (;;) {
    const result = await options.read();
    if (!alive()) return { outcome: "abandoned" };
    if (!result.ok) return { outcome: "failed", error: result.error };

    try {
      options.adopt(result.data);
      return { outcome: "ready" };
    } catch (error) {
      if (left <= 0) return { outcome: "unusable", error };
      left -= 1;
    }
  }
}

export interface ResourceView {
  readonly status: ResourceStatus;
  /** The failure to show, when `status` is `"error"`. */
  readonly message: string;
  /** Try again, in place. */
  readonly reload: () => void;
}

export function useResource<T>(options: ResourceOptions<T>): ResourceView {
  const { key, loaded } = options;

  // The options object is rebuilt every render; the effect must not restart for
  // that. It restarts on `key` (a different thing to read) or on a retry.
  const latest = useRef(options);
  latest.current = options;

  const forced = useRef(false);
  const [attempt, setAttempt] = useState(0);
  const [state, setState] = useState<{ key: string; status: ResourceStatus; message: string }>(
    () => ({ key, status: loaded ? "ready" : "loading", message: "" }),
  );

  useEffect(() => {
    if (latest.current.loaded && !forced.current) {
      setState({ key, status: "ready", message: "" });
      return;
    }
    forced.current = false;

    let live = true;
    setState({ key, status: "loading", message: "" });

    void readUsable<T>({
      read: () => latest.current.read(),
      adopt: (data) => latest.current.onData(data),
      alive: () => live,
    }).then((attempt) => {
      if (!live) return;
      if (attempt.outcome === "ready") {
        setState({ key, status: "ready", message: "" });
        return;
      }
      if (attempt.outcome === "abandoned") return;
      if (attempt.outcome === "failed") {
        if (latest.current.escalate(attempt.error)) return;
        setState({ key, status: "error", message: attempt.error.message });
        return;
      }
      const message = latest.current.onUnusable?.(attempt.error) ?? UNUSABLE_MESSAGE;
      setState({ key, status: "error", message });
    });

    return () => {
      live = false;
    };
  }, [key, attempt]);

  const reload = useCallback(() => {
    forced.current = true;
    setAttempt((n) => n + 1);
  }, []);

  // A render between a `key` change and its effect must not show the previous
  // key's answer.
  if (state.key !== key) return { status: "loading", message: "", reload };
  return { status: state.status, message: state.message, reload };
}
