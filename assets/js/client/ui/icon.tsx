// One way to draw an icon (items 4.2–4.3).
//
// The client shares `app.css` with the LiveView pages, so `hero-*` is already
// there — this is the `<.icon>` component's counterpart, not a second icon set.
//
// Always `aria-hidden`: an icon is decoration on top of text, never the name of
// anything (guardrails §4.1). Spin is `motion-reduce:`-guarded (§1.2).

import type { IconName } from "./icons.ts";
import { iconClass } from "./icons.ts";

export interface IconProps {
  name: IconName;
  /** Sizing and colour. Defaults to the 16px inline size the badges use. */
  className?: string;
  spin?: boolean;
}

export function Icon({ name, className, spin }: IconProps) {
  return (
    <span
      aria-hidden="true"
      className={[
        iconClass(name),
        className ?? "size-4 flex-none",
        spin === true ? "animate-spin motion-reduce:animate-none" : "",
      ]
        .filter((part) => part !== "")
        .join(" ")}
    />
  );
}
