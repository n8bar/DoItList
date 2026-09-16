// The add-task form (m04.02 item 2.2.5).
//
// One form, rendered at the slot it was opened from. Opening it, moving it and
// closing it are pure client state — no round trip stands between the user and
// typing (UX_GUARDRAILS §6.5). ↑ / ↓ walk the insertion point through the tree
// while the typed title rides along; Escape closes and discards; Enter submits
// and leaves the form open, because the button beside it says "Done", not
// "Cancel" — adding several tasks in a row is the common case.
//
// Submitting hands `onAdd` the title and where it goes. This arc stops there:
// the operation adapter is the next task.

import { useEffect, useRef } from "react";

import type { TreeModel } from "./model.ts";
import type { AddRequest, AddSlot } from "./add_form_model.ts";
import { placeholderText, slotKey, submissionFor } from "./add_form_model.ts";

export interface AddFormProps {
  model: TreeModel;
  slot: AddSlot;
  /** ↑ / ↓ moved the insertion point. `null` means there is nowhere to go. */
  onMove: (dir: -1 | 1) => void;
  onClose: () => void;
  onAdd: (request: AddRequest) => void;
}

export function AddForm({ model, slot, onMove, onClose, onAdd }: AddFormProps) {
  const input = useRef<HTMLInputElement | null>(null);
  const key = slotKey(slot);

  // The cursor lands in the box the moment the form appears, and again when it
  // walks to another slot — the point of the walk is to keep typing.
  useEffect(() => {
    input.current?.focus();
    input.current?.scrollIntoView({ block: "nearest" });
  }, [key]);

  return (
    <form
      id="add-task-form"
      data-add-slot={key}
      onSubmit={(event) => {
        event.preventDefault();
        const value = input.current?.value ?? "";
        const request = submissionFor(model, slot, value);
        if (request === null) return;
        onAdd(request);
        if (input.current !== null) {
          input.current.value = "";
          input.current.focus();
        }
      }}
      onClick={(event) => event.stopPropagation()}
      className="flex items-center gap-2 rounded border border-emerald-500/40 bg-white dark:bg-zinc-900 px-3 py-2"
    >
      <input
        ref={input}
        type="text"
        name="title"
        required
        aria-label="Task title"
        placeholder={placeholderText(slot)}
        onKeyDown={(event) => {
          // Scoped to this box: the tree's global handler suppresses itself
          // while a field has focus, so the adder owns its own keys here.
          if (event.key === "Escape") {
            event.preventDefault();
            onClose();
            return;
          }
          if (event.key === "ArrowUp" || event.key === "ArrowDown") {
            // ← / → stay with the text cursor; ↑ / ↓ would otherwise jump it to
            // the start or end of the line.
            event.preventDefault();
            onMove(event.key === "ArrowUp" ? -1 : 1);
          }
        }}
        className="flex-1 input input-bordered input-sm"
      />
      <button
        type="submit"
        className="text-sm px-3 py-1.5 rounded bg-emerald-600 text-white hover:bg-emerald-700 active:bg-emerald-800 active:scale-95 transition"
      >
        Add
      </button>
      {/* "Done", not "Cancel": nothing already added is discarded. */}
      <button
        type="button"
        data-add-cancel
        onClick={onClose}
        className="text-sm px-2 py-1.5 text-zinc-500 hover:text-zinc-800 dark:text-zinc-100 dark:hover:text-white"
      >
        Done
      </button>
    </form>
  );
}
