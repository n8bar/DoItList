// A navigation action that looks like one (m04.01 item 4.4).
//
// Still a real `<a href>` underneath (`Link` owns that contract) — it only
// *looks* like a button. A disabled entry is not an anchor at all: an `<a>` you
// cannot follow is a trap for keyboard and screen-reader users, so it renders
// as a non-focusable `aria-disabled` element instead.

import { Link } from "../router/link.tsx";
import type { ControlStateOptions } from "./button_styles.ts";
import { controlClass } from "./button_styles.ts";

export interface NavButtonProps extends ControlStateOptions {
  id: string;
  to: string;
  label: string;
  /** Ran after the click is handled — the hamburger closes itself with this. */
  onNavigate?: () => void;
}

export function NavButton({ id, to, label, onNavigate, ...state }: NavButtonProps) {
  if (state.disabled === true) {
    return (
      <span id={id} role="link" aria-disabled="true" className={controlClass(state)}>
        {label}
      </span>
    );
  }

  return (
    <Link
      id={id}
      to={to}
      aria-current={state.current === true ? "page" : undefined}
      className={controlClass(state)}
      onClick={() => onNavigate?.()}
    >
      {label}
    </Link>
  );
}
