// The browser client's one way to talk to `/app/api` (m04.01 items 2.2–2.4).
//
// Session cookie + CSRF header, never a bearer token (resilient-client spec
// §12). Every response comes back as a typed `Result` — callers branch on a
// code, never on an HTTP status they have to remember. JSX-free so the whole
// contract, including the stale-session retry, is unit-tested with a fake
// fetch.

export type ApiErrorCode =
  | "unauthorized"
  | "stale_session"
  | "forbidden"
  | "not_found"
  | "conflict"
  | "unprocessable_entity"
  | "network"
  | "malformed";

export interface ApiError {
  code: ApiErrorCode;
  status: number;
  message: string;
  /**
   * The rejected response's body, verbatim, when there was one. A batch
   * rejection carries per-op errors with field `pointer`s under `results`, and
   * a form has to be able to put each message next to the field that caused it
   * (guardrails §2.2) — which it cannot do from a summary sentence.
   */
  payload?: unknown;
}

export type Result<T> = { ok: true; data: T } | { ok: false; error: ApiError };

export interface SessionData {
  user: { id: number; email: string; username: string; name: string | null };
  /**
   * The account's row-display choices. Optional on the type, because a client
   * that outlives a server without them must still start — `rowPreferencesFrom`
   * reads a missing object as the defaults.
   */
  preferences?: {
    show_task_priority: boolean;
    show_task_assignee: boolean;
    show_task_progress: boolean;
    show_task_count: boolean;
  };
  csrf_token: string;
}

export interface ApiClientOptions {
  csrfToken: string;
  /** Injected in tests; defaults to the page's `fetch`. */
  fetchImpl?: typeof fetch;
  /** Injected in tests; defaults to `/app/api`. */
  basePath?: string;
}

export interface ApiClient {
  get<T>(path: string): Promise<Result<T>>;
  /** `headers` are sent verbatim on top of the client's own (e.g. `Idempotency-Key`). */
  post<T>(path: string, body: unknown, headers?: Record<string, string>): Promise<Result<T>>;
  /** Re-reads `GET /app/api/session`, adopting the fresh CSRF token. */
  refreshSession(): Promise<Result<SessionData>>;
  /** The token writes are currently sending. */
  csrfToken(): string;
}

const KNOWN_CODES: readonly string[] = [
  "unauthorized",
  "stale_session",
  "forbidden",
  "not_found",
  "conflict",
  "unprocessable_entity",
];

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function errorFrom(status: number, body: unknown): ApiError {
  const error = isRecord(body) ? body["error"] : null;
  if (isRecord(error)) {
    const code = error["code"];
    const message = error["message"];
    if (typeof code === "string" && KNOWN_CODES.includes(code)) {
      return {
        code: code as ApiErrorCode,
        status,
        message: typeof message === "string" ? message : "Something went wrong.",
        payload: body,
      };
    }
  }
  return {
    code: "malformed",
    status,
    message: `Unexpected response (HTTP ${status}).`,
    payload: body,
  };
}

export function createApiClient(options: ApiClientOptions): ApiClient {
  const basePath = options.basePath ?? "/app/api";
  const doFetch: typeof fetch =
    options.fetchImpl ?? ((input, init) => globalThis.fetch(input, init));
  let csrfToken = options.csrfToken;

  async function send<T>(
    method: "GET" | "POST",
    path: string,
    body: unknown,
    allowRetry: boolean,
    extraHeaders: Record<string, string> = {},
  ): Promise<Result<T>> {
    const headers: Record<string, string> = { accept: "application/json", ...extraHeaders };
    if (method !== "GET") {
      headers["content-type"] = "application/json";
      // The CSRF token is the write credential. There is no bearer token.
      headers["x-csrf-token"] = csrfToken;
    }

    let response: Response;
    try {
      response = await doFetch(`${basePath}${path}`, {
        method,
        headers,
        credentials: "same-origin",
        ...(method === "GET" ? {} : { body: JSON.stringify(body ?? {}) }),
      });
    } catch (cause) {
      return {
        ok: false,
        error: {
          code: "network",
          status: 0,
          message: cause instanceof Error ? cause.message : "The network request failed.",
        },
      };
    }

    let payload: unknown = null;
    try {
      payload = await response.json();
    } catch {
      payload = null;
    }

    if (response.ok) {
      if (isRecord(payload) && "data" in payload) {
        return { ok: true, data: payload["data"] as T };
      }
      // A batch reply is the operations envelope itself — `{results: [...]}`
      // at the top, the same shape `/api/v1/operations` answers with (see
      // `DoItWeb.Client.Api`) — so the envelope is the data.
      if (isRecord(payload) && Array.isArray(payload["results"])) {
        return { ok: true, data: payload as T };
      }
      return {
        ok: false,
        error: { code: "malformed", status: response.status, message: "The response had no data." },
      };
    }

    const error = errorFrom(response.status, payload);

    // A stale CSRF token is recoverable without a reload: re-read the session
    // for a fresh one and replay the write exactly once.
    if (error.code === "stale_session" && allowRetry) {
      const refreshed = await refreshSession();
      if (refreshed.ok) return send<T>(method, path, body, false, extraHeaders);
    }

    return { ok: false, error };
  }

  async function refreshSession(): Promise<Result<SessionData>> {
    const result = await send<SessionData>("GET", "/session", null, false);
    if (result.ok && typeof result.data?.csrf_token === "string") {
      csrfToken = result.data.csrf_token;
    }
    return result;
  }

  return {
    get: <T,>(path: string) => send<T>("GET", path, null, false),
    post: <T,>(path: string, body: unknown, headers?: Record<string, string>) =>
      send<T>("POST", path, body, true, headers),
    refreshSession,
    csrfToken: () => csrfToken,
  };
}
