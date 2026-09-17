import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  DRAG_THRESHOLD_PX,
  IDLE,
  TOUCH_MOVE_TOLERANCE_PX,
  step,
} from "./drag_gesture.ts";
import type { GestureEvent, GestureState, GestureStep, PointerKind } from "./drag_gesture.ts";

const down = (kind: PointerKind, pointerId = 1, button = 0): GestureEvent => ({
  type: "down",
  kind,
  pointerId,
  x: 100,
  y: 200,
  button,
});
const move = (dx: number, dy: number, pointerId = 1): GestureEvent => ({
  type: "move",
  pointerId,
  x: 100 + dx,
  y: 200 + dy,
});
const up = (pointerId = 1): GestureEvent => ({ type: "up", pointerId });

/** Runs the events in order and returns the last step. */
function run(events: readonly GestureEvent[], from: GestureState = IDLE): GestureStep {
  let last: GestureStep = { state: from, effect: { kind: "none" } };
  for (const event of events) last = step(last.state, event);
  return last;
}

describe("mouse and pen", () => {
  for (const kind of ["mouse", "pen"] as const) {
    it(`${kind}: arms on the press without a hold timer`, () => {
      const { state, effect } = run([down(kind)]);
      assert.equal(state.phase, "armed");
      assert.deepEqual(effect, { kind: "arm", longPress: false });
    });

    it(`${kind}: stays armed under the threshold, begins at it`, () => {
      const under = run([down(kind), move(DRAG_THRESHOLD_PX - 1, 0)]);
      assert.equal(under.state.phase, "armed");
      assert.equal(under.effect.kind, "none");

      const at = run([down(kind), move(0, DRAG_THRESHOLD_PX)]);
      assert.equal(at.state.phase, "dragging");
      assert.deepEqual(at.effect, { kind: "begin", x: 100, y: 200 + DRAG_THRESHOLD_PX });
    });

    it(`${kind}: a release before the threshold is a click`, () => {
      const { state, effect } = run([down(kind), move(1, 1), up()]);
      assert.equal(state, IDLE);
      assert.deepEqual(effect, { kind: "click" });
    });

    it(`${kind}: the hold timer means nothing`, () => {
      const { state, effect } = run([down(kind), { type: "hold" }]);
      assert.equal(state.phase, "armed");
      assert.equal(effect.kind, "none");
    });
  }
});

describe("touch", () => {
  it("arms with a hold timer", () => {
    assert.deepEqual(run([down("touch")]).effect, { kind: "arm", longPress: true });
  });

  it("begins when the hold elapses, from where the finger landed", () => {
    const { state, effect } = run([down("touch"), move(2, 3), { type: "hold" }]);
    assert.equal(state.phase, "dragging");
    assert.deepEqual(effect, { kind: "begin", x: 100, y: 200 });
  });

  it("jitter under the tolerance is not a scroll", () => {
    const { state, effect } = run([down("touch"), move(TOUCH_MOVE_TOLERANCE_PX - 1, 0)]);
    assert.equal(state.phase, "armed");
    assert.equal(effect.kind, "none");
  });

  it("moving past the tolerance before the hold is a scroll", () => {
    const scrolled = run([down("touch"), move(0, TOUCH_MOVE_TOLERANCE_PX)]);
    assert.equal(scrolled.state, IDLE);
    assert.deepEqual(scrolled.effect, { kind: "scroll" });
    // The timer that was set for it fires into nothing.
    const late = step(scrolled.state, { type: "hold" });
    assert.equal(late.state, IDLE);
    assert.equal(late.effect.kind, "none");
  });

  it("a lift before the hold is a tap", () => {
    const { state, effect } = run([down("touch"), up()]);
    assert.equal(state, IDLE);
    assert.deepEqual(effect, { kind: "click" });
  });
});

describe("dragging", () => {
  const started = run([down("mouse"), move(10, 0)]).state;

  it("tracks every move", () => {
    const { state, effect } = step(started, move(10, 30));
    assert.equal(state.phase, "dragging");
    assert.deepEqual(effect, { kind: "track", x: 110, y: 230 });
  });

  it("drops on release", () => {
    const { state, effect } = step(started, up());
    assert.equal(state, IDLE);
    assert.deepEqual(effect, { kind: "drop" });
  });

  it("Escape and pointercancel release without a drop", () => {
    const { state, effect } = step(started, { type: "cancel" });
    assert.equal(state, IDLE);
    assert.deepEqual(effect, { kind: "release" });

    const armed = run([down("mouse"), { type: "cancel" }]);
    assert.equal(armed.state, IDLE);
    assert.deepEqual(armed.effect, { kind: "release" });
  });
});

describe("other pointers", () => {
  it("only the primary button arms", () => {
    const { state, effect } = run([down("mouse", 1, 2)]);
    assert.equal(state, IDLE);
    assert.equal(effect.kind, "none");
  });

  it("a second finger is ignored while the first is engaged", () => {
    const armed = run([down("touch"), down("touch", 2), move(50, 50, 2), up(2)]);
    assert.equal(armed.state.phase, "armed");
    assert.equal(armed.effect.kind, "none");

    const dragging = run([down("mouse"), move(10, 0), move(50, 50, 2), up(2)]);
    assert.equal(dragging.state.phase, "dragging");
    assert.equal(dragging.effect.kind, "none");
  });
});
