// What counts as "the app is broken" (m04.01 items 4.2-4.3).
//
// The connection summary's error state is the loudest thing this client can
// say: it replaces the connection state with "Do It List hit a problem" and
// asks for a reload. So the bar is high, and it is set HERE rather than at a
// window listener, where every fire-and-forget promise in the client would
// clear it.
//
// Most rejections are not fatal. A refused IndexedDB write, a blocked upgrade,
// a quota failure — those are storage health, and they belong on the secondary
// storage line where the user can keep working. A cross-origin script error
// arrives with no error object at all and nothing useful to say. Neither gets
// to take the screen over.
//
// Fatal is opt-in: the code that knows it cannot continue says so by marking
// the failure it throws. Render failures are the other route in, and React's
// root boundary already owns those.

const FATAL = Symbol.for("doit.fatal");

/** What we say when a fatal failure carries no message of its own. */
export const FATAL_FALLBACK = "Something in the app stopped working.";

/**
 * Marks a failure as one the tab cannot carry on from. Returns the same object
 * so it can be thrown inline: `throw markFatal(new Error("…"))`.
 *
 * The mark is a non-enumerable symbol: it never shows up in a log line, a
 * spread, or `JSON.stringify`.
 */
export function markFatal<E>(error: E): E {
  if (typeof error === "object" && error !== null) {
    Object.defineProperty(error, FATAL, { value: true, enumerable: false, configurable: true });
  }
  return error;
}

/** True only for a failure the client explicitly marked fatal. */
export function isFatal(reason: unknown): boolean {
  return (
    typeof reason === "object" &&
    reason !== null &&
    (reason as Record<symbol, unknown>)[FATAL] === true
  );
}

/**
 * The sentence to show for a fatal failure, or `null` when the failure is not
 * one — the caller should leave the summary alone.
 */
export function fatalMessage(reason: unknown): string | null {
  if (!isFatal(reason)) return null;
  const message = (reason as { message?: unknown }).message;
  return typeof message === "string" && message !== "" ? message : FATAL_FALLBACK;
}
