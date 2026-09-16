// The narrow-viewport menu (m04.01 items 4.1, 4.4).
//
// Below `sm:` the primary nav collapses behind one control. It is a plain
// disclosure — a button whose `aria-expanded` says whether the panel is open,
// and a panel of the same nav buttons — so it behaves the same for pointer,
// touch and keyboard without a widget role that would promise more than it
// delivers.
//
// Closing rules live in `menu_state.ts`, where they are unit-tested: Escape
// closes AND gives focus back to the trigger; clicking outside or following a
// link closes without taking focus off wherever the user chose to go.

import { useEffect, useReducer, useRef } from "react";

import type { Route } from "../router/route.ts";
import type { Stores } from "../state/stores.ts";
import { controlClass } from "./button_styles.ts";
import { CLOSED_MENU, menuReducer } from "./menu_state.ts";
import { NAV_ITEMS, isCurrentNav } from "./nav_model.ts";
import { NavButton } from "./nav_button.tsx";
import { SignOut } from "./sign_out.tsx";
import { ThemeToggle } from "./theme_toggle.tsx";

export function NavMenu({ stores, route }: { stores: Stores; route: Route }) {
  const [state, dispatch] = useReducer(menuReducer, CLOSED_MENU);
  const trigger = useRef<HTMLButtonElement | null>(null);
  const panel = useRef<HTMLDivElement | null>(null);

  // The focus the reducer said the trigger is owed, paid on the next commit.
  useEffect(() => {
    if (!state.restoreFocus) return;
    trigger.current?.focus();
    dispatch({ kind: "focus-restored" });
  }, [state.restoreFocus]);

  useEffect(() => {
    if (!state.open) return;

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") dispatch({ kind: "close", reason: "escape" });
    };
    // Capture, so a press on something the menu covers closes it before that
    // something reacts.
    const onPointerDown = (event: Event) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (trigger.current?.contains(target) === true) return;
      if (panel.current?.contains(target) === true) return;
      dispatch({ kind: "close", reason: "outside" });
    };

    document.addEventListener("keydown", onKeyDown);
    document.addEventListener("pointerdown", onPointerDown, true);
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.removeEventListener("pointerdown", onPointerDown, true);
    };
  }, [state.open]);

  const close = () => dispatch({ kind: "close", reason: "navigate" });

  return (
    <div className="relative sm:hidden">
      <button
        type="button"
        id="client-menu-button"
        ref={trigger}
        aria-expanded={state.open}
        aria-controls="client-menu"
        className={controlClass({ open: state.open })}
        onClick={() => dispatch({ kind: "toggle" })}
      >
        Menu
      </button>

      {state.open && (
        <div
          id="client-menu"
          ref={panel}
          className="absolute right-0 z-50 mt-2 w-64 rounded-lg border border-zinc-200 bg-white p-2 shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
        >
          <nav aria-label="Menu" className="flex flex-col gap-1">
            {NAV_ITEMS.map((item) => (
              <NavButton
                key={item.key}
                id={`client-menu-nav-${item.key}`}
                to={item.to}
                label={item.label}
                current={isCurrentNav(route, item.key)}
                block
                onNavigate={close}
              />
            ))}
          </nav>
          <div className="my-2 border-t border-zinc-200 dark:border-zinc-700" />
          <div className="flex flex-col gap-1">
            <ThemeToggle stores={stores} id="client-menu-theme-toggle" block />
            <SignOut idPrefix="client-menu" block onSubmitted={close} />
          </div>
        </div>
      )}
    </div>
  );
}
