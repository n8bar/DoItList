// Parsing and state decisions for client startup (m04.01 items 2.2–2.4).
//
// Pure and JSX-free on purpose: every decision the client makes about whether
// it can start — and what screen the user sees when it can't — is unit-tested
// here rather than inferred from a browser. `main.tsx` only wires these results
// to the DOM.

/** The signed-in user, exactly as `DoItWeb.Api.Identity` reports them. */
export interface BootstrapUser {
  id: number;
  email: string;
  username: string;
  name: string | null;
}

/** The document's starting facts. No bearer token — the session cookie is the credential. */
export interface Bootstrap {
  user: BootstrapUser | null;
  csrfToken: string;
  path: string;
}

export type BootstrapResult =
  | { ok: true; bootstrap: Bootstrap }
  | { ok: false; message: string };

/**
 * The screen the client is showing. `loading` is what the server painted;
 * everything else is a decision this module made.
 */
export type ClientState =
  | { kind: "loading" }
  | { kind: "ready"; user: BootstrapUser }
  | { kind: "signed-out" }
  | { kind: "asset-failed" }
  | { kind: "start-failed"; message: string }
  | { kind: "forbidden" };

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

function parseUser(value: unknown): BootstrapUser | null | undefined {
  if (value === null || value === undefined) return null;
  if (!isRecord(value)) return undefined;
  const { id, email, username, name } = value;
  if (typeof id !== "number" || typeof email !== "string" || typeof username !== "string") {
    return undefined;
  }
  return { id, email, username, name: typeof name === "string" ? name : null };
}

/**
 * Reads the `<script type="application/json" id="bootstrap">` payload.
 *
 * Anything unexpected is a failure with a human message, never a half-filled
 * object: a client that starts on garbage is worse than one that says it
 * couldn't start.
 */
export function parseBootstrap(raw: string | null | undefined): BootstrapResult {
  if (typeof raw !== "string" || raw.trim() === "") {
    return { ok: false, message: "The page didn't include its startup data." };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return { ok: false, message: "The page's startup data was not valid JSON." };
  }

  if (!isRecord(parsed)) {
    return { ok: false, message: "The page's startup data was not an object." };
  }

  const csrfToken = parsed["csrf_token"];
  if (typeof csrfToken !== "string" || csrfToken === "") {
    return { ok: false, message: "The page's startup data had no CSRF token." };
  }

  const user = parseUser(parsed["user"]);
  if (user === undefined) {
    return { ok: false, message: "The page's startup data had an unreadable user." };
  }

  const path = parsed["path"];

  return {
    ok: true,
    bootstrap: {
      user,
      csrfToken,
      path: typeof path === "string" && path !== "" ? path : "/app",
    },
  };
}

/** The first screen after startup: signed out, ready, or an explicit failure. */
export function initialState(result: BootstrapResult): ClientState {
  if (!result.ok) return { kind: "start-failed", message: result.message };
  const { user } = result.bootstrap;
  return user === null ? { kind: "signed-out" } : { kind: "ready", user };
}

/**
 * The session read named a different account than the page was served to
 * (m04.03 5.1.2): the socket, the user channel and the cache were all opened
 * as the bootstrap's user, so nothing this tab does from here on is safe. One
 * plain sentence for the summary's unrecoverable state, or `null` when they
 * match (or the page had nobody to compare with).
 */
export function identityMismatch(
  bootstrapUser: BootstrapUser | null,
  sessionUser: { id: number },
): string | null {
  if (bootstrapUser === null || bootstrapUser.id === sessionUser.id) return null;
  return "You’re signed in as a different account now. Reload to continue.";
}

/** Where an `/app/api` failure code sends the user. `null` = stay put, handle locally. */
export function stateForErrorCode(code: string, message = ""): ClientState | null {
  switch (code) {
    case "unauthorized":
      return { kind: "signed-out" };
    case "forbidden":
      return { kind: "forbidden" };
    case "network":
    case "malformed":
      return { kind: "start-failed", message };
    default:
      return null;
  }
}

/** The login URL that returns the user to where they were. */
export function loginPath(path: string): string {
  return `/users/log_in?return_to=${encodeURIComponent(path || "/app")}`;
}
