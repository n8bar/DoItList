// When a link click belongs to the client, and when it belongs to the browser
// (m04.01 item 3.2).
//
// Pure, and JSX-free, so every modifier combination is unit-tested rather than
// discovered by a user whose cmd-click reloaded the page instead of opening a
// tab.

import { internalPath } from "./route.ts";

/** The parts of a click event the decision depends on. */
export interface ClickFacts {
  button: number;
  metaKey: boolean;
  ctrlKey: boolean;
  shiftKey: boolean;
  altKey: boolean;
  defaultPrevented: boolean;
}

/**
 * True only for the plain left-click the client can serve instantly. Anything
 * else — a modifier, a middle-click, an explicit `target`, an off-app path, or
 * a handler that already called `preventDefault` — falls through to the
 * browser, which is what the user asked for.
 */
export function handledLocally(event: ClickFacts, to: string, target: string | null): boolean {
  if (event.defaultPrevented) return false;
  if (event.button !== 0) return false;
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
  if (target !== null && target !== "" && target !== "_self") return false;
  return internalPath(to);
}
