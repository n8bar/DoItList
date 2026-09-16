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
  onData: (data: T) => void;
  /** See `Services.escalate` — `true` means the shell took the failure over. */
  escalate: (error: ApiError) => boolean;
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

    void latest.current.read().then((result) => {
      if (!live) return;
      if (result.ok) {
        latest.current.onData(result.data);
        setState({ key, status: "ready", message: "" });
        return;
      }
      if (latest.current.escalate(result.error)) return;
      setState({ key, status: "error", message: result.error.message });
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
