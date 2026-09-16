// The narrow-viewport menu, as a state machine (m04.01 items 4.1, 4.4).
//
// Small, but worth pulling out: "closing puts focus back on the trigger" is a
// keyboard-user promise (UX_GUARDRAILS §3) and it is only true for SOME ways of
// closing. Pressing Escape means "take me back to where I was" — focus returns.
// Clicking outside, or following a link out of the menu, means the user has
// already chosen where to be — yanking focus back to the hamburger would be the
// app overruling them.

export interface MenuState {
  readonly open: boolean;
  /** The frame owes the trigger a `focus()` on the next commit. */
  readonly restoreFocus: boolean;
}

export type CloseReason = "escape" | "trigger" | "outside" | "navigate" | "wide";

export type MenuEvent =
  | { kind: "toggle" }
  | { kind: "close"; reason: CloseReason }
  /** The frame has given the trigger its focus back. */
  | { kind: "focus-restored" };

export const CLOSED_MENU: MenuState = { open: false, restoreFocus: false };

/**
 * Which ways of closing hand focus back to the trigger. Only Escape: closing
 * by the trigger leaves focus on it already, and the other three are the user
 * having chosen somewhere else to be.
 */
function restores(reason: CloseReason): boolean {
  return reason === "escape";
}

export function menuReducer(state: MenuState, event: MenuEvent): MenuState {
  switch (event.kind) {
    case "toggle":
      // Opening never needs a restore; closing by the trigger itself leaves
      // focus where it already is (on the trigger) — no steal, no restore.
      return state.open ? CLOSED_MENU : { open: true, restoreFocus: false };
    case "close":
      if (!state.open) return state;
      return { open: false, restoreFocus: restores(event.reason) };
    case "focus-restored":
      return state.restoreFocus ? { ...state, restoreFocus: false } : state;
  }
}
