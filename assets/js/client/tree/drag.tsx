// The drag gesture on the tree's rows (m04.02 items 3.3.2, 3.3.3).
//
// The impure half of `drag_gesture.ts` and `drag_model.ts`, and the port of
// what `Hooks.DragReorder` does with the DOM: it listens for the pointer,
// measures which row is under it, and paints the answer. Every decision is
// borrowed — `step` says what phase the gesture is in, `bandFor` and
// `resolveDrop` say what a drop here would mean — so nothing in this file
// needs a browser to be checked except the measuring itself.
//
// Two things differ from the hook on purpose (item 3.3.3):
//
//   * the root zones and each open branch's tail strip exist only while a drag
//     is on. `dragging` is React state; `tree.tsx` mounts them from it, and the
//     hook's "always-present tail" is gone;
//   * the dragged row never moves. It is dimmed where it is, the drop emits one
//     `move` intent, and the tree re-renders from the model when the move
//     lands (worklist 5 answers the intent). No optimistic DOM surgery, no
//     pending-move handle to reconcile against a patch.
//
// The highlight classes (`dragging-source`, `drop-target`, `drop-forbidden`,
// `is-over`) and the placeholder `<li>` are toggled on the elements directly,
// as the hook does: they change on every pointer move, and routing them
// through state would re-render every row for a ring around one of them. The
// rows keep their keys; React never sees the placeholder.

import { useCallback, useEffect, useMemo, useRef } from "react";
import type { RefObject } from "react";

import type { TreeContext } from "./context.ts";
import type { Source } from "./task_store.ts";
import { createStore } from "../state/store.ts";
import { childIdsOf } from "./model.ts";
import { bandFor, resolveDrop } from "./drag_model.ts";
import type { DropHit, DropTarget } from "./drag_model.ts";
import { IDLE, LONG_PRESS_MS, step } from "./drag_gesture.ts";
import type { GestureEffect, GestureEvent, GestureState, PointerKind } from "./drag_gesture.ts";

/** Dragging within this many px of the scroll box's top / bottom auto-scrolls. */
const EDGE_SCROLL_ZONE_PX = 64;
/** Max auto-scroll step per frame, at the very edge. */
const EDGE_SCROLL_MAX_PX = 16;

/** The swipe-instead-of-hold hint shows at most this often per browser session. */
const DRAG_HINT_CAP = 3;
const DRAG_HINT_KEY = "doit:drag-hint-count";

/** The handle grows while a touch hold counts down. */
const PRIMING_CLASSES = ["scale-110", "motion-safe:transition-transform", "motion-safe:duration-200"];

const NO_HIT: DropHit = { kind: "none" };
const NO_TARGET: DropTarget = { kind: "none" };

/** The two slim targets bracketing the root list. */
export function RootZone({ zone }: { zone: "top" | "bottom" }) {
  return <li className="drop-root-zone" data-zone={zone} aria-hidden="true" />;
}

/** "Last child of this branch", as the last `<li>` of its child list. */
export function TailZone({ branchId }: { branchId: number }) {
  return <li className="drop-tail" data-branch={branchId} aria-hidden="true" />;
}

/**
 * Binds the gesture to every `[data-drag-handle]` under `list`, for as long
 * as the viewer may edit. Returns whether a drag is on, as a store the
 * overlays subscribe to (7.18): a drag starting mounts the drop zones and
 * re-renders no row.
 */
export function useTreeDrag(ctx: TreeContext, list: RefObject<HTMLUListElement | null>): Source<boolean> {
  const dragging = useMemo(() => createStore(false), []);
  const setDragging = useCallback((on: boolean) => dragging.set(on), [dragging]);
  // Bound once; the session always reads the ctx of the latest render.
  const latest = useRef(ctx);
  latest.current = ctx;
  const canEdit = ctx.permissions.canEdit;

  useEffect(() => {
    const ul = list.current;
    if (!canEdit || ul === null) return;
    const session = new DragSession(ul, () => latest.current, setDragging);
    ul.addEventListener("pointerdown", session.onPointerDown);
    return () => {
      ul.removeEventListener("pointerdown", session.onPointerDown);
      session.teardown();
    };
  }, [canEdit, list]);

  return dragging;
}

/** One gesture at a time: the pointer facts in, the effects carried out. */
class DragSession {
  private state: GestureState = IDLE;
  private handle: HTMLElement | null = null;
  private source: HTMLElement | null = null;
  private sourceId = 0;
  private target: DropTarget = NO_TARGET;
  private painted: { el: Element; cls: string }[] = [];
  private readonly placeholder: HTMLLIElement;
  private holdTimer: ReturnType<typeof setTimeout> | null = null;
  private frame: number | null = null;
  private scroller: Element | null = null;
  private last: { x: number; y: number } | null = null;

  constructor(
    private readonly ul: HTMLUListElement,
    private readonly ctx: () => TreeContext,
    private readonly setDragging: (on: boolean) => void,
  ) {
    this.placeholder = document.createElement("li");
    this.placeholder.className = "drop-placeholder";
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
    // Ours now: no text selection, no focus change on the row.
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

  /** Feeds one fact to the reducer and carries out its effect. */
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
        if (effect.longPress && this.handle !== null) {
          this.handle.classList.add(...PRIMING_CLASSES);
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
      case "scroll":
        this.teardown();
        // The user swiped the handle instead of holding it: say how it works,
        // a few times per session, so a returning phone user is re-taught
        // without being nagged.
        if (countDragHint()) this.ctx().onDragHint?.();
        return;
      case "click":
      case "release":
        this.teardown();
        return;
      case "drop": {
        // pointerup is followed by a synthetic click on whatever is under the
        // pointer; without this the row there would select itself.
        suppressNextClick();
        const target = this.target;
        const id = this.sourceId;
        // The overlays come down before the intent goes out, so a re-render it
        // triggers never meets the placeholder.
        this.teardown();
        if ("plan" in target) {
          const { parentId, position, reorder } = target.plan;
          this.ctx().onIntent({ kind: "move", id, parentId, position, reorder });
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
    const handle = this.handle;
    const source = handle?.closest("li[data-task-id]");
    if (!(handle instanceof HTMLElement) || !(source instanceof HTMLElement)) {
      this.state = IDLE;
      this.teardown();
      return;
    }
    this.source = source;
    this.sourceId = Number(source.dataset.taskId);
    source.classList.add("dragging-source");
    document.body.style.userSelect = "none";
    document.body.style.cursor = "grabbing";
    // Keeps the moves coming when the pointer leaves the window mid-drag.
    if (this.state.phase === "dragging") {
      try {
        handle.setPointerCapture(this.state.pointerId);
      } catch {
        // A pointer that is already gone cannot be captured; the document
        // listeners still see whatever it sends.
      }
    }
    this.scroller = scrollContainer(handle);
    this.setDragging(true);
    this.startEdgeScroll();
  }

  /** Resolves what a drop at (x, y) would do, and paints it. */
  private track(x: number, y: number): void {
    this.last = { x, y };
    const target = resolveDrop(this.ctx().tasks.model(), { sourceId: this.sourceId, hit: this.hitAt(x, y) });
    this.target = target;
    this.paint(target);
  }

  /** What is under the pointer, measured; `drag_model.ts` decides what it means. */
  private hitAt(x: number, y: number): DropHit {
    const source = this.source;
    if (source === null) return NO_HIT;
    // The source is skipped so the pointer near it does not anchor on itself.
    const prev = source.style.pointerEvents;
    source.style.pointerEvents = "none";
    const el = document.elementFromPoint(x, y);
    source.style.pointerEvents = prev;
    if (el === null || !this.ul.contains(el)) return NO_HIT;

    const zone = el.closest("li.drop-root-zone");
    if (zone instanceof HTMLElement) return { kind: "zone", zone: zone.dataset.zone === "top" ? "top" : "bottom" };

    const tail = el.closest("li.drop-tail");
    if (tail instanceof HTMLElement) return { kind: "tail", branchId: Number(tail.dataset.branch) };

    const li = el.closest("li[data-task-id]");
    if (!(li instanceof HTMLElement)) return NO_HIT;
    const anchorId = Number(li.dataset.taskId);
    // The row strip only, not the subtree under it.
    const rect = (li.firstElementChild ?? li).getBoundingClientRect();
    const ctx = this.ctx();
    const expanded = childIdsOf(ctx.tasks.model(), anchorId).length > 0 && !ctx.collapse.get(anchorId);
    return { kind: "row", anchorId, band: bandFor(rect.top, rect.height, y, expanded) };
  }

  private paint(target: DropTarget): void {
    this.clearPaint();
    document.body.style.cursor = target.kind === "forbidden" ? "not-allowed" : "grabbing";
    switch (target.kind) {
      case "none":
        return;
      case "forbidden":
        this.mark(this.row(target.anchorId), "drop-forbidden");
        return;
      case "zone":
        this.mark(this.ul.querySelector(`:scope > li.drop-root-zone[data-zone="${target.zone}"]`), "is-over");
        return;
      case "tail":
        this.mark(this.ul.querySelector(`li.drop-tail[data-branch="${target.branchId}"]`), "is-over");
        return;
      case "reparent":
        this.mark(this.row(target.anchorId), "drop-target");
        return;
      case "placeholder": {
        const anchor = this.row(target.anchorId);
        const parent = anchor?.parentElement;
        if (anchor === null || !parent) return;
        parent.insertBefore(this.placeholder, target.band === "above" ? anchor : anchor.nextSibling);
        return;
      }
    }
  }

  private row(id: number): Element | null {
    return this.ul.querySelector(`li[data-task-id="${id}"]`);
  }

  private mark(el: Element | null, cls: string): void {
    if (el === null) return;
    el.classList.add(cls);
    this.painted.push({ el, cls });
  }

  private clearPaint(): void {
    for (const { el, cls } of this.painted) el.classList.remove(cls);
    this.painted = [];
    this.placeholder.remove();
  }

  // Scrolls the box while the pointer sits near its top / bottom edge, faster
  // the deeper into the zone, and re-resolves after each scroll so the
  // highlight tracks the rows sliding under a pointer that is not moving.
  private startEdgeScroll(): void {
    if (this.frame !== null) return;
    const tick = (): void => {
      if (this.state.phase !== "dragging") {
        this.frame = null;
        return;
      }
      this.edgeScrollStep();
      this.frame = requestAnimationFrame(tick);
    };
    this.frame = requestAnimationFrame(tick);
  }

  private edgeScrollStep(): void {
    const el = this.scroller;
    const last = this.last;
    if (el === null || last === null) return;

    const isDocument = el === document.scrollingElement || el === document.documentElement || el === document.body;
    const rect = isDocument ? null : el.getBoundingClientRect();
    const top = rect === null ? 0 : rect.top;
    const bottom = rect === null ? window.innerHeight : rect.bottom;

    const y = last.y;
    let delta = 0;
    if (y < top + EDGE_SCROLL_ZONE_PX) {
      const f = Math.min((top + EDGE_SCROLL_ZONE_PX - y) / EDGE_SCROLL_ZONE_PX, 1);
      delta = -Math.ceil(EDGE_SCROLL_MAX_PX * f);
    } else if (y > bottom - EDGE_SCROLL_ZONE_PX) {
      const f = Math.min((y - (bottom - EDGE_SCROLL_ZONE_PX)) / EDGE_SCROLL_ZONE_PX, 1);
      delta = Math.ceil(EDGE_SCROLL_MAX_PX * f);
    }
    if (delta === 0) return;

    const before = el.scrollTop;
    el.scrollTop = before + delta;
    if (el.scrollTop !== before) this.track(last.x, last.y);
  }

  private clearHold(): void {
    if (this.holdTimer !== null) {
      clearTimeout(this.holdTimer);
      this.holdTimer = null;
    }
    this.handle?.classList.remove(...PRIMING_CLASSES);
  }

  /** Back to nothing on screen, whatever phase this was in. */
  teardown(): void {
    this.clearHold();
    this.unbind();
    this.clearPaint();
    if (this.frame !== null) {
      cancelAnimationFrame(this.frame);
      this.frame = null;
    }
    if (this.source !== null) {
      this.source.classList.remove("dragging-source");
      this.source.style.pointerEvents = "";
    }
    document.body.style.userSelect = "";
    document.body.style.cursor = "";
    this.source = null;
    this.handle = null;
    this.sourceId = 0;
    this.target = NO_TARGET;
    this.scroller = null;
    this.last = null;
    this.state = IDLE;
    this.setDragging(false);
  }
}

function pointerKind(type: string): PointerKind {
  return type === "touch" || type === "pen" ? type : "mouse";
}

/** The nearest scrolling ancestor — `#client-scroll` in the frame — else the page. */
function scrollContainer(from: Element): Element {
  let el = from.parentElement;
  while (el !== null) {
    const oy = getComputedStyle(el).overflowY;
    if ((oy === "auto" || oy === "scroll") && el.scrollHeight > el.clientHeight) return el;
    el = el.parentElement;
  }
  return document.scrollingElement ?? document.documentElement;
}

/** Bumps the session's hint count; true while it is still under the cap. */
function countDragHint(): boolean {
  try {
    const shown = Number(sessionStorage.getItem(DRAG_HINT_KEY) ?? "0");
    if (shown >= DRAG_HINT_CAP) return false;
    sessionStorage.setItem(DRAG_HINT_KEY, String(shown + 1));
    return true;
  } catch {
    // Storage blocked: no cap to keep, and no hint either — better silent
    // than nagging on every swipe.
    return false;
  }
}

/** Swallows the click the browser synthesises right after a drop's pointerup. */
function suppressNextClick(): void {
  const swallow = (event: MouseEvent): void => {
    event.preventDefault();
    event.stopPropagation();
    event.stopImmediatePropagation();
    document.removeEventListener("click", swallow, true);
    clearTimeout(timeout);
  };
  document.addEventListener("click", swallow, true);
  // The synthetic click is effectively synchronous; 50ms is well clear of it
  // and well short of anything the user could click on purpose.
  const timeout = setTimeout(() => document.removeEventListener("click", swallow, true), 50);
}
