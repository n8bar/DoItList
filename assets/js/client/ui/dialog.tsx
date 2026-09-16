// Dialogs (item 4.2, UX_GUARDRAILS §3.1, §6.5).
//
// A native `<dialog>` opened with `showModal()`. That choice is the whole
// design: the platform gives us the top layer, the focus trap, `inert` on
// everything behind it and Escape, all of which are easy to write badly and
// impossible to write better. What the platform does not do reliably is put
// focus back on an opener that React has re-rendered in the meantime, so we
// remember the opener ourselves (`dialog_model.ts`).
//
// It opens CLIENT-SIDE, always. A confirm is the client asking a question it
// already knows the wording of; making the user wait on a round trip to be
// asked "are you sure?" is the anti-pattern §6.5 exists to forbid.
//
// Escape, the backdrop and Cancel all mean "no" — only the confirm button means
// yes. The caller owns `open`, so the answer and the closing are one state
// change rather than two sources of truth.

import type { ReactNode, SyntheticEvent } from "react";
import { useEffect, useRef } from "react";

import { actionClass } from "../frame/button_styles.ts";
import type { FocusTarget } from "./dialog_model.ts";
import { dialogIds, restoreFocus } from "./dialog_model.ts";

export interface DialogProps {
  /** Stable, unique: every id inside the dialog is derived from it. */
  id: string;
  open: boolean;
  /** The dialog's name. Announced through `aria-labelledby`. */
  title: string;
  /** Escape, the backdrop, or a Cancel control. Never a yes. */
  onCancel: () => void;
  /** The footer's controls, in reading order. */
  actions?: ReactNode;
  children: ReactNode;
}

const PANEL = [
  "m-auto w-[min(28rem,calc(100vw-2rem))] rounded-xl border p-5 text-left align-middle",
  "border-zinc-200 bg-white text-zinc-900 shadow-xl",
  "dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-100",
  "backdrop:bg-black/40",
].join(" ");

export function Dialog({ id, open, title, onCancel, actions, children }: DialogProps) {
  const ref = useRef<HTMLDialogElement | null>(null);
  const opener = useRef<FocusTarget | null>(null);
  const ids = dialogIds(id);

  useEffect(() => {
    const dialog = ref.current;
    if (dialog === null) return;

    if (open && !dialog.open) {
      // Remembered BEFORE the dialog takes focus, because a moment later the
      // active element is inside the dialog.
      const active = document.activeElement;
      opener.current = active instanceof HTMLElement ? active : null;
      dialog.showModal();
      // Where focus lands is a decision, not an accident: the dialog says which
      // control is the safe one to land on, and the platform's "first focusable
      // element" is only right by luck.
      const preferred = dialog.querySelector("[data-autofocus]");
      if (preferred instanceof HTMLElement) preferred.focus();
      return;
    }

    if (!open && dialog.open) {
      dialog.close();
      restoreFocus(opener.current);
      opener.current = null;
    }
  }, [open]);

  // Unmounted while open — the menu it lived in went away, or the route
  // changed — nobody else will hand focus back, and the browser drops it on
  // <body>. `opener` is non-null only while the dialog is open, so this is a
  // no-op in every other case.
  useEffect(
    () => () => {
      if (opener.current === null) return;
      restoreFocus(opener.current);
      opener.current = null;
    },
    [],
  );

  // Escape closes a native dialog by itself. We stop it and hand the decision
  // to the caller instead, so the DOM and `open` can never disagree.
  const onCancelEvent = (event: SyntheticEvent<HTMLDialogElement>) => {
    event.preventDefault();
    onCancel();
  };

  return (
    <dialog
      id={id}
      ref={ref}
      aria-labelledby={ids.titleId}
      aria-describedby={ids.descriptionId}
      className={PANEL}
      onCancel={onCancelEvent}
      // A press on the backdrop reports the dialog itself as the target.
      onClick={(event) => {
        if (event.target === ref.current) onCancel();
      }}
    >
      <h2 id={ids.titleId} className="text-base font-semibold">
        {title}
      </h2>
      <div id={ids.descriptionId} className="mt-2 text-sm text-zinc-700 dark:text-zinc-300">
        {children}
      </div>
      {actions !== undefined && <div className="mt-5 flex justify-end gap-2">{actions}</div>}
    </dialog>
  );
}

export interface ConfirmDialogProps {
  id: string;
  open: boolean;
  title: string;
  /** What the user is agreeing to, in their terms. */
  children: ReactNode;
  /** The yes control's label. A verb, never "OK" (guardrails §4.1). */
  confirmLabel: string;
  cancelLabel?: string;
  /** The action destroys or discards something: red, and never the default. */
  danger?: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}

/**
 * A confirm: one question, two answers, no third way to leave it ambiguous.
 * Cancel is focused first — the safe answer is the one the keyboard lands on.
 */
export function ConfirmDialog({
  id,
  open,
  title,
  children,
  confirmLabel,
  cancelLabel = "Cancel",
  danger = false,
  onConfirm,
  onCancel,
}: ConfirmDialogProps) {
  const ids = dialogIds(id);

  return (
    <Dialog
      id={id}
      open={open}
      title={title}
      onCancel={onCancel}
      actions={
        <>
          <button
            type="button"
            id={ids.cancelId}
            data-autofocus
            className={actionClass()}
            onClick={onCancel}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            id={ids.confirmId}
            className={actionClass({ variant: danger ? "danger" : "primary" })}
            onClick={onConfirm}
          >
            {confirmLabel}
          </button>
        </>
      }
    >
      {children}
    </Dialog>
  );
}
