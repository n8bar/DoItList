// The pane's own field claim (m04.03 4.1.1): which Details-pane field this
// window is in, announced through presence so other windows can say "<Name>
// is editing this too" — and dropped again when the user leaves the field,
// the pane closes, or nothing has been typed for a while, so a tab someone
// walked away from does not hold the claim all afternoon.
//
// Plain object, injected timers: `node --test` drives it. Advisory only —
// nothing here is waited on and nothing is locked by it (§6).

import type { Timers } from "../live/connection.ts";
import type { EditField } from "../live/presence_model.ts";

/** Two minutes without a keystroke and the claim lapses. */
export const CLAIM_IDLE_MS = 120_000;

export interface FieldClaim {
  /** The user is in `field` now. */
  focus(field: EditField): void;
  /** The user typed in the field they are in; a lapsed claim is made again. */
  input(): void;
  /** The user left the field (or it went away). */
  blur(): void;
  /** The pane is gone: drop the claim and every timer. */
  dispose(): void;
  /** What is announced right now. */
  current(): EditField | null;
}

export function createFieldClaim(
  announce: (field: EditField | null) => void,
  timers: Timers = {
    setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
    clearTimeout: (handle) => globalThis.clearTimeout(handle as number),
  },
  idleMs: number = CLAIM_IDLE_MS,
): FieldClaim {
  /** The field the user is in, whether or not the claim has lapsed. */
  let focused: EditField | null = null;
  /** What was last announced. */
  let announced: EditField | null = null;
  let handle: unknown = null;

  const say = (field: EditField | null) => {
    if (announced === field) return;
    announced = field;
    announce(field);
  };

  const stop = () => {
    if (handle === null) return;
    timers.clearTimeout(handle);
    handle = null;
  };

  const arm = () => {
    stop();
    handle = timers.setTimeout(() => {
      handle = null;
      say(null);
    }, idleMs);
  };

  return {
    focus(field) {
      focused = field;
      say(field);
      arm();
    },
    input() {
      if (focused === null) return;
      say(focused);
      arm();
    },
    blur() {
      focused = null;
      stop();
      say(null);
    },
    dispose() {
      focused = null;
      stop();
      say(null);
    },
    current: () => announced,
  };
}
