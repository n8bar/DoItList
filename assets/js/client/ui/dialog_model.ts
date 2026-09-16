// The parts of a dialog that are rules, not markup (item 4.2).
//
// Two of them, and both are promises to a keyboard user:
//
//   * the dialog is NAMED — its `aria-labelledby` points at its own heading and
//     its `aria-describedby` at its own body, so it announces as something
//     rather than as "dialog" (guardrails §4.1);
//   * closing hands focus back to whatever opened it (§3.1) — and every way out
//     except pressing the confirm button means "no".
//
// Native `<dialog>` + `showModal()` does the trapping, the inertness and the
// top layer for us, which is why there is no focus-trap implementation here.
// What it does NOT reliably do is put focus back on an opener that has since
// been re-rendered, so that part is ours, and it is here where it is testable.

export interface DialogIds {
  readonly titleId: string;
  readonly descriptionId: string;
  readonly cancelId: string;
  readonly confirmId: string;
}

export function dialogIds(id: string): DialogIds {
  return {
    titleId: `${id}-title`,
    descriptionId: `${id}-description`,
    cancelId: `${id}-cancel`,
    confirmId: `${id}-confirm`,
  };
}

/** Escape, the Cancel button, a press outside, or the confirm button. */
export type DialogCloseReason = "escape" | "cancel" | "backdrop" | "confirm";

/**
 * Only the confirm button confirms. Escape and a stray click are how people
 * back out of things, and treating either as a yes is how destructive actions
 * happen by accident.
 */
export function outcomeFor(reason: DialogCloseReason): "confirm" | "cancel" {
  return reason === "confirm" ? "confirm" : "cancel";
}

/** The little an element needs to be worth handing focus back to. */
export interface FocusTarget {
  readonly isConnected: boolean;
  focus(): void;
}

/**
 * Puts focus back on the opener, and says whether it could. An opener that has
 * left the document is not focusable — focusing it would silently move focus to
 * `<body>`, which is the "where am I?" a keyboard user cannot recover from.
 */
export function restoreFocus(opener: FocusTarget | null): boolean {
  if (opener === null || !opener.isConnected) return false;
  opener.focus();
  return true;
}
