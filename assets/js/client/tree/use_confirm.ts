// One open confirm, holding the write it is deciding (m04.02 item 5.1.4).
//
// `request` is the gate every tree write passes through on its way to the
// adapter: a write that needs no confirm, or whose class the user has silenced,
// goes straight on; otherwise it is held here until Proceed submits it or
// Cancel drops it. Nothing reaches the adapter while the dialog is open, and a
// cancel leaves the model exactly as it was. (Holding the row's optimistic
// flip while the question is open is item 5.2's.)

import { useCallback, useRef, useState } from "react";

import type { KeyValueStore } from "../storage/last_user.ts";
import type { TreeWrite } from "./adapter.ts";
import type { Confirm } from "./confirm_model.ts";
import { confirmFor, ensureSkipVersion, suppress, suppressed } from "./confirm_model.ts";
import type { TreeModel } from "./model.ts";

export interface OpenConfirm {
  readonly confirm: Confirm;
  readonly write: TreeWrite;
}

export interface ConfirmState {
  /** The confirm waiting on an answer, or `null`. */
  readonly open: OpenConfirm | null;
  /** "Don't show this again" — the box's state while the dialog is open. */
  readonly dontAsk: boolean;
  setDontAsk(checked: boolean): void;
  /** Ask if the write needs it, else submit it now. */
  request(write: TreeWrite): void;
  proceed(): void;
  cancel(): void;
}

export interface UseConfirmOptions {
  model: TreeModel;
  submit: (write: TreeWrite) => void;
  /** The page's localStorage, or `null` where there is none. */
  storage: KeyValueStore | null;
}

export function useConfirm({ model, submit, storage }: UseConfirmOptions): ConfirmState {
  const [open, setOpen] = useState<OpenConfirm | null>(null);
  const [dontAsk, setDontAsk] = useState(false);

  // Read at request time, not at render, so a write asked for mid-update is
  // judged against the model it will be sent from.
  const modelRef = useRef(model);
  modelRef.current = model;
  const submitRef = useRef(submit);
  submitRef.current = submit;

  const versioned = useRef(false);
  if (!versioned.current) {
    versioned.current = true;
    ensureSkipVersion(storage);
  }

  const request = useCallback(
    (write: TreeWrite) => {
      const confirm = confirmFor(modelRef.current, write);
      if (confirm === null || suppressed(storage, confirm.class)) {
        submitRef.current(write);
        return;
      }
      setDontAsk(false);
      setOpen({ confirm, write });
    },
    [storage],
  );

  const proceed = useCallback(() => {
    if (open === null) return;
    if (dontAsk) suppress(storage, open.confirm.class);
    setOpen(null);
    submitRef.current(open.write);
  }, [open, dontAsk, storage]);

  const cancel = useCallback(() => setOpen(null), []);

  return { open, dontAsk, setDontAsk, request, proceed, cancel };
}
