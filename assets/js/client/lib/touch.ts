// The touch layout choice for the React client (m04.02 item 7.8).
//
// Held the way the theme is (`lib/theme.ts`): on the DEVICE, never on the
// account — the same phone wants the touch layout whoever is signed in, and the
// same account wants it off at a desk. The first-paint script in
// `lib/doit_web/components/layouts/theme_script.html.heex` reads the same
// `phx:touch` key and puts `data-touch` on `<html>` before anything renders;
// this module is its in-app half. A first visit follows `(pointer: coarse)`.
// The environment is injected so this stays pure and unit-testable.

export const TOUCH_KEY = "phx:touch";

export interface TouchEnv {
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem">;
  root: {
    toggleAttribute(name: string, force?: boolean): boolean;
  };
  coarsePointer(): boolean;
}

/** A saved "on"/"off" wins; anything else follows the pointer. */
export function resolveTouch(saved: string | null, coarsePointer: boolean): boolean {
  if (saved === "on") return true;
  if (saved === "off") return false;
  return coarsePointer;
}

/** Whether the touch layout is on for this device right now. */
export function currentTouch(env: TouchEnv): boolean {
  return resolveTouch(env.storage.getItem(TOUCH_KEY), env.coarsePointer());
}

/** Saves the choice on the device and applies it to the document element. */
export function setTouch(on: boolean, env: TouchEnv): void {
  env.storage.setItem(TOUCH_KEY, on ? "on" : "off");
  env.root.toggleAttribute("data-touch", on);
}

/** The real browser environment. Touches globals only when called. */
export function browserTouchEnv(): TouchEnv {
  return {
    storage: window.localStorage,
    root: document.documentElement,
    coarsePointer: () => window.matchMedia("(pointer: coarse)").matches,
  };
}
