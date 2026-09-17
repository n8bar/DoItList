// How a press on a handle becomes a drag (m04.02 item 3.3.2).
//
// The `DragReorder` hook's state machine with the DOM taken out. The hook
// decides "is this a click, a scroll, or a drag?" inside its event handlers,
// mixed in with class toggling and timers; here that decision is a reducer
// over pointer facts, so each rule can be tested with numbers:
//
//   IDLE
//     -- pointerdown on a handle --> ARMED   (nothing on screen yet)
//   ARMED
//     -- mouse / pen moves DRAG_THRESHOLD_PX --> DRAGGING
//     -- touch holds LONG_PRESS_MS, jitter under TOUCH_MOVE_TOLERANCE_PX --> DRAGGING
//     -- touch moves TOUCH_MOVE_TOLERANCE_PX before the hold --> IDLE  (a scroll)
//     -- pointerup --> IDLE  (a click)
//     -- pointercancel / Escape --> IDLE
//   DRAGGING
//     -- pointermove --> track the pointer
//     -- pointerup --> drop
//     -- pointercancel / Escape --> IDLE, nothing committed
//
// Every step returns the next state and one effect for `drag.tsx` to carry
// out — bind listeners, start the hold timer, mount the overlays, resolve the
// row under the pointer, commit. The pointer that armed is the only one heard;
// a second finger is ignored, as the hook ignores it.

/** Mouse and pen must move this far before a drag begins. */
export const DRAG_THRESHOLD_PX = 4;
/** Touch must hold this long without significant motion to begin a drag. */
export const LONG_PRESS_MS = 400;
/** Touch jitter allowed during the hold before it reads as a scroll. */
export const TOUCH_MOVE_TOLERANCE_PX = 8;

export type PointerKind = "mouse" | "pen" | "touch";

export type GestureState =
  | { readonly phase: "idle" }
  | {
      readonly phase: "armed";
      readonly kind: PointerKind;
      readonly pointerId: number;
      readonly startX: number;
      readonly startY: number;
    }
  | { readonly phase: "dragging"; readonly kind: PointerKind; readonly pointerId: number };

export type GestureEvent =
  | {
      readonly type: "down";
      readonly kind: PointerKind;
      readonly pointerId: number;
      readonly x: number;
      readonly y: number;
      /** 0 is the primary button; touch reports 0. */
      readonly button: number;
    }
  | { readonly type: "move"; readonly pointerId: number; readonly x: number; readonly y: number }
  | { readonly type: "up"; readonly pointerId: number }
  /** The long-press timer elapsed. */
  | { readonly type: "hold" }
  /** pointercancel, or Escape. */
  | { readonly type: "cancel" };

export type GestureEffect =
  | { readonly kind: "none" }
  /** Listen for the rest of the gesture; `longPress` asks for the hold timer. */
  | { readonly kind: "arm"; readonly longPress: boolean }
  /** Mount the overlays, then track from here. */
  | { readonly kind: "begin"; readonly x: number; readonly y: number }
  /** Resolve what is under the pointer. */
  | { readonly kind: "track"; readonly x: number; readonly y: number }
  /** Released before a drag began: let the click through, unbind. */
  | { readonly kind: "click" }
  /** Touch moved before the hold: the page is scrolling, unbind. */
  | { readonly kind: "scroll" }
  /** Commit whatever the last track resolved, then unbind. */
  | { readonly kind: "drop" }
  /** Unbind, nothing committed. */
  | { readonly kind: "release" };

export const IDLE: GestureState = { phase: "idle" };

const NONE: GestureEffect = { kind: "none" };

export interface GestureStep {
  readonly state: GestureState;
  readonly effect: GestureEffect;
}

/** One pointer fact in; the next state and what to do about it out. */
export function step(state: GestureState, event: GestureEvent): GestureStep {
  switch (state.phase) {
    case "idle":
      if (event.type !== "down" || event.button !== 0) return { state, effect: NONE };
      return {
        state: {
          phase: "armed",
          kind: event.kind,
          pointerId: event.pointerId,
          startX: event.x,
          startY: event.y,
        },
        effect: { kind: "arm", longPress: event.kind === "touch" },
      };

    case "armed":
      switch (event.type) {
        case "down":
          return { state, effect: NONE };
        case "move": {
          if (event.pointerId !== state.pointerId) return { state, effect: NONE };
          const dist = Math.hypot(event.x - state.startX, event.y - state.startY);
          if (state.kind === "touch") {
            // Motion before the hold is the user scrolling, not priming a drag.
            if (dist >= TOUCH_MOVE_TOLERANCE_PX) return { state: IDLE, effect: { kind: "scroll" } };
            return { state, effect: NONE };
          }
          if (dist < DRAG_THRESHOLD_PX) return { state, effect: NONE };
          return { state: dragging(state), effect: { kind: "begin", x: event.x, y: event.y } };
        }
        case "hold":
          if (state.kind !== "touch") return { state, effect: NONE };
          return {
            state: dragging(state),
            effect: { kind: "begin", x: state.startX, y: state.startY },
          };
        case "up":
          if (event.pointerId !== state.pointerId) return { state, effect: NONE };
          return { state: IDLE, effect: { kind: "click" } };
        case "cancel":
          return { state: IDLE, effect: { kind: "release" } };
      }

    case "dragging":
      switch (event.type) {
        case "down":
        case "hold":
          return { state, effect: NONE };
        case "move":
          if (event.pointerId !== state.pointerId) return { state, effect: NONE };
          return { state, effect: { kind: "track", x: event.x, y: event.y } };
        case "up":
          if (event.pointerId !== state.pointerId) return { state, effect: NONE };
          return { state: IDLE, effect: { kind: "drop" } };
        case "cancel":
          return { state: IDLE, effect: { kind: "release" } };
      }
  }
}

function dragging(armed: GestureState & { phase: "armed" }): GestureState {
  return { phase: "dragging", kind: armed.kind, pointerId: armed.pointerId };
}
