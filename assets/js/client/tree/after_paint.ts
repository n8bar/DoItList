// Work that must wait for a paint (m04.02 item 7.8.8).
//
// A click's acknowledgement — the chevron's glyph flipping — is written to the
// DOM in the click's own task; the collapse it asks for re-renders the whole
// tree today (item 7.9) and would hold that paint back if it ran in the same
// task. `afterPaint` runs the heavy part a frame later and then a task later:
// the frame callback runs just before the next paint, so a task queued from
// inside it runs after that paint, with the flip on screen. The environment
// is injected so the ordering is unit-tested without a browser.

export interface PaintEnv {
  /** Runs `cb` just before the next paint (requestAnimationFrame). */
  frame(cb: () => void): void;
  /** Runs `cb` in a later task (setTimeout 0). */
  later(cb: () => void): void;
}

export function afterPaint(work: () => void, env: PaintEnv = browserPaintEnv()): void {
  env.frame(() => env.later(work));
}

/** The real browser environment. Touches globals only when called. */
export function browserPaintEnv(): PaintEnv {
  return {
    frame: (cb) => void window.requestAnimationFrame(() => cb()),
    later: (cb) => void window.setTimeout(cb, 0),
  };
}
