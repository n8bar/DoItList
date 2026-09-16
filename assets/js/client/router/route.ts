// The client's route table (m04.01 item 3.2).
//
// The client mounts at `/app` and mirrors the product's paths one for one:
// `/app/initiatives`, `/app/initiatives/:id`, `/app/assigned`, `/app/account`.
// LiveView keeps the bare paths until Arc 7, so the two can run side by side.
//
// `matchRoute` is a pure function of the pathname — the *same* function answers
// a direct load, a refresh, a `<Link>` click and a back button, which is what
// makes guardrail §7.1 ("the same path always shows the same content") true by
// construction rather than by coincidence.

/** Where the client is mounted. Every route below is under this prefix. */
export const BASE_PATH = "/app";

/** The route a bare `/app` (or an unknown path's escape hatch) resolves to. */
export const HOME_PATH = "/app/initiatives";

export type Route =
  | { kind: "initiatives" }
  | { kind: "initiative"; id: number }
  | { kind: "assigned" }
  | { kind: "account" }
  /** `/app` itself: nothing to render, the router replaces it with `to`. */
  | { kind: "redirect"; to: string }
  /** Anything else under `/app`, plus anything outside it. */
  | { kind: "not-found"; path: string };

/** Splits a pathname into its non-empty segments; trailing slashes vanish. */
function segments(pathname: string): string[] {
  return pathname.split("/").filter((segment) => segment !== "");
}

/** A positive integer id, or `null`. Rejects `1.5`, `1e3`, `+1`, `abc`, `""`. */
export function parseId(raw: string): number | null {
  if (!/^[0-9]+$/.test(raw)) return null;
  const id = Number(raw);
  return Number.isSafeInteger(id) && id > 0 ? id : null;
}

/**
 * Resolves a pathname to a route. Accepts a full URL's pathname only — query
 * strings and hashes are the caller's business (strip them first).
 */
export function matchRoute(pathname: string): Route {
  const path = typeof pathname === "string" && pathname !== "" ? pathname : "/";
  const parts = segments(path);

  if (parts[0] !== "app") return { kind: "not-found", path };

  const rest = parts.slice(1);

  if (rest.length === 0) return { kind: "redirect", to: HOME_PATH };

  if (rest.length === 1) {
    switch (rest[0]) {
      case "initiatives":
        return { kind: "initiatives" };
      case "assigned":
        return { kind: "assigned" };
      case "account":
        return { kind: "account" };
      default:
        return { kind: "not-found", path };
    }
  }

  if (rest.length === 2 && rest[0] === "initiatives") {
    const id = parseId(rest[1] ?? "");
    return id === null ? { kind: "not-found", path } : { kind: "initiative", id };
  }

  return { kind: "not-found", path };
}

/** The canonical path for a route — `matchRoute(routePath(r))` is `r`. */
export function routePath(route: Route): string {
  switch (route.kind) {
    case "initiatives":
      return HOME_PATH;
    case "initiative":
      return `${HOME_PATH}/${route.id}`;
    case "assigned":
      return `${BASE_PATH}/assigned`;
    case "account":
      return `${BASE_PATH}/account`;
    case "redirect":
      return route.to;
    case "not-found":
      return route.path;
  }
}

/** True when the client owns this path, i.e. a `<Link>` may intercept it. */
export function internalPath(path: string): boolean {
  return path === BASE_PATH || path.startsWith(`${BASE_PATH}/`);
}
