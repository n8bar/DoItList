// The theme toggle (m04.01 worklist 2, rehomed into the frame by item 4.1).
//
// Entirely local: the click changes the document attribute and the preference
// store in the same tick, so the theme flips instantly and no round trip stands
// between the user and the control (UX_GUARDRAILS §6.7).
//
// It holds a fixed width. The label cycles System → Light → Dark, and letting a
// three-letter word shrink the control would shove its neighbours sideways
// every time somebody pressed it (item 4.6).

import { setThemePreference } from "../state/preferences.ts";
import type { Stores } from "../state/stores.ts";
import { useStore } from "../state/use_store.ts";
import type { ThemePreference } from "../lib/theme.ts";
import { browserThemeEnv, nextPreference, setTheme } from "../lib/theme.ts";
import { controlClass } from "./button_styles.ts";

export const THEME_LABEL: Record<ThemePreference, string> = {
  system: "System",
  light: "Light",
  dark: "Dark",
};

export interface ThemeToggleProps {
  stores: Stores;
  id?: string;
  className?: string;
  block?: boolean;
}

export function ThemeToggle({ stores, id, className, block }: ThemeToggleProps) {
  const { theme } = useStore(stores.preferences);

  return (
    <button
      type="button"
      id={id ?? "client-theme-toggle"}
      aria-label={`Theme: ${THEME_LABEL[theme]}. Switch theme`}
      title={`Theme: ${THEME_LABEL[theme]}`}
      className={[
        controlClass(block === true ? { block } : {}),
        block === true ? "" : "min-w-24",
        className ?? "",
      ]
        .filter((part) => part !== "")
        .join(" ")}
      onClick={() => {
        const next = nextPreference(theme);
        setTheme(next, browserThemeEnv());
        setThemePreference(stores.preferences, next);
      }}
    >
      {THEME_LABEL[theme]}
    </button>
  );
}
