// The touch layout switch (m04.02 item 7.8).
//
// 👆 beside the theme toggle: a two-state switch that turns the touch-friendly
// tree layout on and off for this DEVICE (`lib/touch.ts`, the `phx:touch`
// key the first-paint script reads). Entirely local, like the theme: the press
// flips `<html data-touch>` and the preference store in the same tick, so the
// tree re-lays instantly and no round trip stands between the user and the
// control (UX_GUARDRAILS §6.7). Nothing is ever sent to the account.

import { setTouchPreference } from "../state/preferences.ts";
import type { Stores } from "../state/stores.ts";
import { useStore } from "../state/use_store.ts";
import { browserTouchEnv, setTouch } from "../lib/touch.ts";
import { themeGroupClass } from "./theme_toggle_model.ts";
import {
  TOUCH_SWITCH_GLYPH,
  TOUCH_SWITCH_LABEL,
  touchSwitchClass,
  touchSwitchTitle,
} from "./touch_switch_model.ts";

export interface TouchSwitchProps {
  stores: Stores;
  id?: string;
  className?: string;
  block?: boolean;
}

export function TouchSwitch({ stores, id, className, block }: TouchSwitchProps) {
  const { touch } = useStore(stores.preferences);

  return (
    <div
      className={[themeGroupClass(block === true), className ?? ""]
        .filter((part) => part !== "")
        .join(" ")}
    >
      <button
        type="button"
        id={id ?? "client-touch-switch"}
        data-touch-switch
        role="switch"
        aria-checked={touch}
        aria-label={TOUCH_SWITCH_LABEL}
        title={touchSwitchTitle(touch)}
        className={touchSwitchClass(touch)}
        onClick={() => {
          setTouch(!touch, browserTouchEnv());
          setTouchPreference(stores.preferences, !touch);
        }}
      >
        <span aria-hidden="true" className="text-base leading-none">
          {TOUCH_SWITCH_GLYPH}
        </span>
        <span className="sr-only">{TOUCH_SWITCH_LABEL}</span>
      </button>
    </div>
  );
}
