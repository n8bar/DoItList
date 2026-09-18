// The tree's keydown listener (m04.02 item 2.2.4).
//
// The thin, impure half of `keyboard_model.ts`: it owns the three things a pure
// function cannot know — whether a text field has focus, the `idclip` letter
// buffer, and whether the browser's default should be prevented — and hands
// everything else to the model. `.TaskKeys`'s `inField()` rule, kept exactly:
// while an input, textarea, select or contenteditable has focus the tree keeps
// its hands off, so native editing (including the field's own undo) still works.

import { useEffect, useRef } from "react";

import type { KeyOutcome, KeyboardState, Modifiers } from "./keyboard_model.ts";
import { handleKey, nextIdclipBuffer } from "./keyboard_model.ts";

/** True while something that accepts typing has focus. */
export function inField(active: Element | null): boolean {
  if (active === null) return false;
  if (active instanceof HTMLElement && active.isContentEditable) return true;
  return ["INPUT", "TEXTAREA", "SELECT"].includes(active.tagName);
}

export interface TreeKeyboardOptions {
  /** Rebuilt every render; the listener always reads the latest. */
  state: KeyboardState;
  /** What to do about the model's answer. */
  onOutcome: (outcome: KeyOutcome) => void;
  /** False while the tree is not the thing on screen. */
  enabled?: boolean;
}

export function useTreeKeyboard({ state, onOutcome, enabled = true }: TreeKeyboardOptions): void {
  // One listener for the life of the screen. Re-binding it on every keystroke
  // would drop events between the unbind and the bind.
  const latest = useRef({ state, onOutcome });
  latest.current = { state, onOutcome };
  const idclip = useRef("");

  useEffect(() => {
    if (!enabled) return;

    const onKeyDown = (event: KeyboardEvent): void => {
      // The target too: a field's own Enter handler blurs it before this
      // listener runs, and that Enter is the field's, not a deselect.
      if (inField(document.activeElement) || inField(event.target as Element | null)) return;

      const step = nextIdclipBuffer(idclip.current, event.key);
      idclip.current = step.buffer;
      if (step.triggered) {
        event.preventDefault();
        latest.current.onOutcome({ kind: "idclip" });
        return;
      }

      const mods: Modifiers = {
        alt: event.altKey,
        shift: event.shiftKey,
        ctrl: event.ctrlKey,
        meta: event.metaKey,
      };
      const outcome = handleKey(latest.current.state, event.key, mods);
      if (outcome.kind === "none") return;

      // The tree answered, so the browser must not also scroll the page.
      event.preventDefault();
      latest.current.onOutcome(outcome);
    };

    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [enabled]);
}
