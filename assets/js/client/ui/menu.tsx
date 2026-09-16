// The shared menu (item 4.2).
//
// A button that opens a list of actions: the tree tools, a row's overflow, a
// filter picker. It is NOT the frame's hamburger — that one is a disclosure
// holding navigation and it stays where it is (`frame/menu.tsx`). This one
// holds ACTIONS, so it is a real `menu`/`menuitem` widget with the keyboard
// behaviour that role promises: arrows move, Home and End jump, Escape closes
// and gives the trigger its focus back.
//
// Open/close — and who is owed focus when it closes — is `frame/menu_state.ts`,
// the same reducer the hamburger uses; where the arrows go is `menu_model.ts`.
// Nothing about either is re-decided here.
//
// Entirely client-side: opening a menu is view state and never waits on the
// network (guardrail §6.5).

import { useEffect, useReducer, useRef, useState } from "react";

import { controlClass } from "../frame/button_styles.ts";
import { CLOSED_MENU, menuReducer } from "../frame/menu_state.ts";
import { Icon } from "./icon.tsx";
import type { MenuItemModel } from "./menu_model.ts";
import { firstEnabled, menuItemDomId, nextFocusIndex } from "./menu_model.ts";

export interface MenuProps {
  /** Stable and unique; every item's id is derived from it. */
  id: string;
  /** The trigger's visible text. */
  label: string;
  items: readonly MenuItemModel[];
  /** Runs for the chosen item. The menu closes first, so focus lands sanely. */
  onSelect: (itemId: string) => void;
  /** Extra classes on the wrapper, e.g. a breakpoint that hides this instance. */
  className?: string;
}

const ITEM_BASE = [
  "flex w-full min-h-11 items-center gap-2 rounded-lg px-3 py-1.5 text-left text-sm font-medium",
  "transition-colors motion-reduce:transition-none",
  "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-emerald-600",
  "dark:focus-visible:ring-emerald-400",
  "sm:min-h-9",
].join(" ");

const ITEM_STATE = {
  normal:
    "text-zinc-700 hover:bg-zinc-100 active:bg-zinc-200 dark:text-zinc-200 dark:hover:bg-zinc-800 dark:active:bg-zinc-700",
  danger:
    "text-red-700 hover:bg-red-50 active:bg-red-100 dark:text-red-300 dark:hover:bg-red-950/50 dark:active:bg-red-950/80",
  disabled: "cursor-not-allowed text-zinc-400 dark:text-zinc-600",
};

export function Menu({ id, label, items, onSelect, className }: MenuProps) {
  const [state, dispatch] = useReducer(menuReducer, CLOSED_MENU);
  const [focused, setFocused] = useState(-1);
  const trigger = useRef<HTMLButtonElement | null>(null);
  const panel = useRef<HTMLDivElement | null>(null);

  // The focus the reducer says the trigger is owed, paid on the next commit.
  useEffect(() => {
    if (!state.restoreFocus) return;
    trigger.current?.focus();
    dispatch({ kind: "focus-restored" });
  }, [state.restoreFocus]);

  // Opening puts focus on the first item the user can actually use — a menu
  // that opens with focus nowhere is a menu a keyboard user has to hunt for.
  useEffect(() => {
    if (!state.open) {
      setFocused(-1);
      return;
    }
    setFocused(firstEnabled(items) ?? -1);
  }, [state.open, items]);

  useEffect(() => {
    if (!state.open || focused < 0) return;
    const item = items[focused];
    if (item === undefined) return;
    const element = document.getElementById(menuItemDomId(id, item.id));
    element?.focus();
  }, [state.open, focused, id, items]);

  useEffect(() => {
    if (!state.open) return;

    // Capture, so a press on something the menu covers closes it before that
    // something reacts.
    const onPointerDown = (event: Event) => {
      const target = event.target;
      if (!(target instanceof Node)) return;
      if (trigger.current?.contains(target) === true) return;
      if (panel.current?.contains(target) === true) return;
      dispatch({ kind: "close", reason: "outside" });
    };

    document.addEventListener("pointerdown", onPointerDown, true);
    return () => document.removeEventListener("pointerdown", onPointerDown, true);
  }, [state.open]);

  const choose = (item: MenuItemModel) => {
    if (item.disabled === true) return;
    // Closed first: the action may replace what is under the menu, and a menu
    // left open over new content is a menu pointing at the wrong thing.
    dispatch({ kind: "close", reason: "navigate" });
    trigger.current?.focus();
    onSelect(item.id);
  };

  return (
    <div
      className={`relative${className === undefined ? "" : ` ${className}`}`}
      // Escape on the WRAPPER, not the panel: focus is on the trigger the
      // moment the menu opens by click, and Escape has to shut it from there
      // too (§3.3). The reducer hands focus back to the trigger.
      onKeyDown={(event) => {
        if (event.key !== "Escape" || !state.open) return;
        // An open dialog owns Escape. One of this menu's items opens a confirm
        // that lives inside the panel, and answering it must not also shut the
        // menu out from under the control the dialog has to hand focus back to.
        if (event.target instanceof Element && event.target.closest("dialog[open]") !== null) {
          return;
        }
        event.stopPropagation();
        dispatch({ kind: "close", reason: "escape" });
      }}
    >
      <button
        type="button"
        id={`${id}-button`}
        ref={trigger}
        aria-expanded={state.open}
        aria-haspopup="menu"
        aria-controls={`${id}-list`}
        className={controlClass({ open: state.open })}
        onClick={() => dispatch({ kind: "toggle" })}
      >
        {label}
        <Icon name="chevron-down" className="size-4 flex-none" />
      </button>

      <div
        id={`${id}-list`}
        ref={panel}
        role="menu"
        aria-label={label}
        hidden={!state.open}
        className="absolute right-0 z-50 mt-2 w-64 rounded-lg border border-zinc-200 bg-white p-2 shadow-lg dark:border-zinc-700 dark:bg-zinc-900"
        onKeyDown={(event) => {
          // Escape is the wrapper's; it bubbles there from here.
          const next = nextFocusIndex(items, focused, event.key);
          if (next === null) return;
          event.preventDefault();
          setFocused(next);
        }}
      >
        {items.map((item, index) => (
          <button
            key={item.id}
            type="button"
            id={menuItemDomId(id, item.id)}
            role="menuitem"
            // One stop for the whole menu: Tab leaves it, the arrows move
            // inside it. That is what `menu` promises a keyboard user.
            tabIndex={index === focused ? 0 : -1}
            aria-disabled={item.disabled === true}
            className={[
              ITEM_BASE,
              item.disabled === true
                ? ITEM_STATE.disabled
                : item.danger === true
                  ? ITEM_STATE.danger
                  : ITEM_STATE.normal,
            ].join(" ")}
            onClick={() => choose(item)}
          >
            {item.label}
          </button>
        ))}
      </div>
    </div>
  );
}
