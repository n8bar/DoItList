// Dragging a card to reorder the Initiatives index (m04.02 item 4.4).
//
// The port of `Hooks.InitiativeDrag`: a press on the card's handle, the same
// thresholds (mouse moves 4px; touch holds 400ms with 8px of jitter), the
// dragged card dimmed in place, and a `div.init-drop-placeholder` on the side
// of the card under the pointer the row would land. The gesture's phases come
// from `tree/drag_gesture.ts`, the tree's own reducer, so this file only
// measures and paints; which side of a card a drop means is `dropSide` in
// `initiatives_model.ts`, tested with numbers.
//
// A drop hands the page one `InitiativeDrop`; the page reorders the list and
// writes it. Nothing here moves a card: the placeholder is inserted and
// removed directly, as the hook does, and React never sees it.

import { useEffect, useRef } from "react";
import type { RefObject } from "react";

import { IDLE, LONG_PRESS_MS, step } from "../tree/drag_gesture.ts";
import type { GestureEffect, GestureEvent, GestureState, PointerKind } from "../tree/drag_gesture.ts";
import { dropSide } from "./initiatives_model.ts";
import type { DropSide } from "./initiatives_model.ts";

export interface InitiativeDrop {
  readonly sourceId: number;
  readonly targetId: number;
  readonly side: DropSide;
}

/**
 * Binds the gesture to every `[data-drag-handle]` under `list` while
 * `present` — the list is only rendered once there are cards, so the binding
 * follows it. `onDrop` is called once per completed drag with a target; the
 * latest one is always the one called.
 */
export function useInitiativeDrag(
  list: RefObject<HTMLElement | null>,
  present: boolean,
  onDrop: (drop: InitiativeDrop) => void,
): void {
  const latest = useRef(onDrop);
  latest.current = onDrop;

  useEffect(() => {
    const el = list.current;
    if (!present || el === null) return;
    const session = new DragSession(el, (drop) => latest.current(drop));
    el.addEventListener("pointerdown", session.onPointerDown);
    return () => {
      el.removeEventListener("pointerdown", session.onPointerDown);
      session.teardown();
    };
  }, [list, present]);
}

/** One gesture at a time: the pointer facts in, the effects carried out. */
class DragSession {
  private state: GestureState = IDLE;
  private handle: HTMLElement | null = null;
  private card: HTMLElement | null = null;
  private target: { id: number; side: DropSide } | null = null;
  private holdTimer: ReturnType<typeof setTimeout> | null = null;
  private readonly placeholder: HTMLDivElement;

  constructor(
    private readonly list: HTMLElement,
    private readonly onDrop: (drop: InitiativeDrop) => void,
  ) {
    this.placeholder = document.createElement("div");
    this.placeholder.className = "init-drop-placeholder";
    this.placeholder.setAttribute("aria-hidden", "true");
  }

  readonly onPointerDown = (event: PointerEvent): void => {
    const handle =
      event.target instanceof Element ? event.target.closest("[data-drag-handle]") : null;
    if (!(handle instanceof HTMLElement) || this.state.phase !== "idle") return;
    this.handle = handle;
    const armed = this.dispatch({
      type: "down",
      kind: pointerKind(event.pointerType),
      pointerId: event.pointerId,
      x: event.clientX,
      y: event.clientY,
      button: event.button,
    });
    if (!armed) return;
    // Ours now: no text selection, and the card's link does not start a
    // navigation or a native drag from its handle.
    event.preventDefault();
    event.stopPropagation();
  };

  private readonly onPointerMove = (event: PointerEvent): void => {
    this.dispatch({ type: "move", pointerId: event.pointerId, x: event.clientX, y: event.clientY });
  };
  private readonly onPointerUp = (event: PointerEvent): void => {
    this.dispatch({ type: "up", pointerId: event.pointerId });
  };
  private readonly onCancel = (): void => {
    this.dispatch({ type: "cancel" });
  };
  private readonly onKeyDown = (event: KeyboardEvent): void => {
    if (event.key === "Escape") this.dispatch({ type: "cancel" });
  };

  private dispatch(event: GestureEvent): boolean {
    const next = step(this.state, event);
    this.state = next.state;
    this.apply(next.effect);
    return next.effect.kind !== "none";
  }

  private apply(effect: GestureEffect): void {
    switch (effect.kind) {
      case "none":
        return;
      case "arm":
        this.bind();
        if (effect.longPress) {
          this.holdTimer = setTimeout(() => {
            this.holdTimer = null;
            this.dispatch({ type: "hold" });
          }, LONG_PRESS_MS);
        }
        return;
      case "begin":
        this.begin();
        this.track(effect.x, effect.y);
        return;
      case "track":
        this.track(effect.x, effect.y);
        return;
      case "click":
      case "scroll":
      case "release":
        this.teardown();
        return;
      case "drop": {
        // pointerup is followed by a synthetic click on whatever is under the
        // pointer; without this the card there would open.
        suppressNextClick();
        const card = this.card;
        const target = this.target;
        this.teardown();
        if (card !== null && target !== null) {
          this.onDrop({ sourceId: cardId(card), targetId: target.id, side: target.side });
        }
        return;
      }
    }
  }

  private bind(): void {
    document.addEventListener("pointermove", this.onPointerMove);
    document.addEventListener("pointerup", this.onPointerUp);
    document.addEventListener("pointercancel", this.onCancel);
    document.addEventListener("keydown", this.onKeyDown);
  }

  private unbind(): void {
    document.removeEventListener("pointermove", this.onPointerMove);
    document.removeEventListener("pointerup", this.onPointerUp);
    document.removeEventListener("pointercancel", this.onCancel);
    document.removeEventListener("keydown", this.onKeyDown);
  }

  private begin(): void {
    this.clearHold();
    const card = this.handle?.closest("[data-initiative-id]");
    if (!(card instanceof HTMLElement) || card.parentElement !== this.list) {
      this.state = IDLE;
      this.teardown();
      return;
    }
    this.card = card;
    card.style.opacity = "0.5";
    document.body.style.userSelect = "none";
    document.body.style.cursor = "grabbing";
    // Keeps the moves coming when the pointer leaves the window mid-drag.
    if (this.state.phase === "dragging" && this.handle !== null) {
      try {
        this.handle.setPointerCapture(this.state.pointerId);
      } catch {
        // A pointer already gone cannot be captured; the document listeners
        // still see whatever it sends.
      }
    }
  }

  /** The card under the pointer, and which side of it; painted as the placeholder. */
  private track(x: number, y: number): void {
    this.placeholder.remove();
    this.target = null;
    const under = document.elementFromPoint(x, y);
    const over = under?.closest("[data-initiative-id]");
    if (
      !(over instanceof HTMLElement) ||
      over === this.card ||
      over.parentElement !== this.list
    ) {
      return;
    }
    const rect = over.getBoundingClientRect();
    const side = dropSide(rect.top, rect.height, y);
    this.target = { id: cardId(over), side };
    this.list.insertBefore(this.placeholder, side === "after" ? over.nextSibling : over);
  }

  private clearHold(): void {
    if (this.holdTimer !== null) {
      clearTimeout(this.holdTimer);
      this.holdTimer = null;
    }
  }

  /** Back to nothing on screen, whatever phase this was in. */
  teardown(): void {
    this.clearHold();
    this.unbind();
    this.placeholder.remove();
    if (this.card !== null) this.card.style.opacity = "";
    document.body.style.userSelect = "";
    document.body.style.cursor = "";
    this.card = null;
    this.handle = null;
    this.target = null;
    this.state = IDLE;
  }
}

function cardId(card: HTMLElement): number {
  return Number(card.dataset["initiativeId"]);
}

function pointerKind(type: string): PointerKind {
  return type === "touch" || type === "pen" ? type : "mouse";
}

/** Swallows the click that follows a drop's pointerup, and only that one. */
function suppressNextClick(): void {
  const swallow = (event: MouseEvent): void => {
    event.preventDefault();
    event.stopPropagation();
    document.removeEventListener("click", swallow, true);
    clearTimeout(timer);
  };
  document.addEventListener("click", swallow, true);
  const timer = setTimeout(() => document.removeEventListener("click", swallow, true), 50);
}
