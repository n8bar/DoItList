// The theme toggle (m04.01 worklist 2, rehomed into the frame by item 4.1,
// restored to the product's three-way group by item 4.7).
//
// System / Light / Dark, three joined segments, the one in force pressed in —
// the same control the LiveView header has (`Layouts.theme_toggle` `:group`),
// so `/app` and the rest of the product are visibly one product. It is exempt
// from item 4's "one control per action" tidying on purpose: the choice IS
// three-way, and showing all three is how the user reads which one is on
// without pressing anything.
//
// Entirely local: the press changes the document attribute and the preference
// store in the same tick, so the theme flips instantly and no round trip stands
// between the user and the control (UX_GUARDRAILS §6.7).
//
// The group's size never depends on which segment is on (see
// `theme_toggle_model.ts`), so pressing one cannot shove its neighbours
// sideways (item 4.4).

import { setThemePreference } from "../state/preferences.ts";
import type { Stores } from "../state/stores.ts";
import { useStore } from "../state/use_store.ts";
import { browserThemeEnv, setTheme } from "../lib/theme.ts";
import { Icon } from "../ui/icon.tsx";
import {
  THEME_SEGMENTS,
  segmentClass,
  themeGroupClass,
  themeSegmentId,
} from "./theme_toggle_model.ts";

export interface ThemeToggleProps {
  stores: Stores;
  id?: string;
  className?: string;
  block?: boolean;
}

export function ThemeToggle({ stores, id, className, block }: ThemeToggleProps) {
  const { theme } = useStore(stores.preferences);
  const controlId = id ?? "client-theme-toggle";

  return (
    <div
      id={controlId}
      role="group"
      aria-label="Theme"
      className={[themeGroupClass(block === true), className ?? ""]
        .filter((part) => part !== "")
        .join(" ")}
    >
      {THEME_SEGMENTS.map((segment, position) => {
        const active = theme === segment.preference;
        return (
          <button
            key={segment.preference}
            type="button"
            id={themeSegmentId(controlId, segment.preference)}
            data-theme-choice={segment.preference}
            aria-label={segment.ariaLabel}
            aria-pressed={active}
            title={segment.title}
            className={segmentClass({ active, position })}
            onClick={() => {
              setTheme(segment.preference, browserThemeEnv());
              setThemePreference(stores.preferences, segment.preference);
            }}
          >
            <Icon name={segment.icon} className="size-4 flex-none" />
            <span className="sr-only">{segment.label}</span>
          </button>
        );
      })}
    </div>
  );
}
