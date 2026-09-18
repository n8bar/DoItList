// The touch layout switch, as data (m04.02 item 7.8).
//
// A two-state switch beside the theme toggle: on, the tree's completion box
// and chevron take a 44×44 tap (app.css `[data-touch]`); off, the default
// layout draws them at 24. It looks like one segment of the theme group so the
// two read as one row of device settings, and — like the group — it keeps one
// size whichever way it is set, so pressing it cannot shove its neighbours
// sideways (m04.01 item 4.4).

import { segmentClass } from "./theme_toggle_model.ts";

export const TOUCH_SWITCH_LABEL = "Touch layout";

/** The pointing hand. */
export const TOUCH_SWITCH_GLYPH = "\u{1F446}";

/** The pointer tooltip — on or off in words, not colour alone (guardrails §4.1). */
export function touchSwitchTitle(on: boolean): string {
  return `${TOUCH_SWITCH_LABEL}: ${on ? "on" : "off"}`;
}

/** The button's classes: the theme group's lone segment, filled when on. */
export function touchSwitchClass(on: boolean): string {
  return segmentClass({ active: on, position: 0 });
}
