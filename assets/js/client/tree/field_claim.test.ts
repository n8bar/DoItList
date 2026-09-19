import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { EditField } from "../live/presence_model.ts";
import { createFieldClaim } from "./field_claim.ts";

/** Timers under test control: `fire()` runs everything due. */
function fakeTimers() {
  const due: Array<{ at: number; run: () => void }> = [];
  let now = 0;
  return {
    timers: {
      setTimeout(callback: () => void, ms: number) {
        const entry = { at: now + ms, run: callback };
        due.push(entry);
        return entry;
      },
      clearTimeout(handle: unknown) {
        const at = due.indexOf(handle as { at: number; run: () => void });
        if (at >= 0) due.splice(at, 1);
      },
    },
    advance(ms: number) {
      now += ms;
      for (const entry of [...due].filter((e) => e.at <= now)) {
        due.splice(due.indexOf(entry), 1);
        entry.run();
      }
    },
    pending: () => due.length,
  };
}

function claim() {
  const said: Array<EditField | null> = [];
  const clock = fakeTimers();
  const unit = createFieldClaim((field) => said.push(field), clock.timers, 1000);
  return { unit, said, clock };
}

describe("the pane's field claim (4.1.1)", () => {
  it("announces the field on focus, once, and clears it on blur", () => {
    const { unit, said } = claim();
    unit.focus("title");
    unit.focus("title");
    assert.deepEqual(said, ["title"]);
    unit.blur();
    unit.blur();
    assert.deepEqual(said, ["title", null]);
    assert.equal(unit.current(), null);
  });

  it("moving to another field announces that one", () => {
    const { unit, said } = claim();
    unit.focus("title");
    unit.focus("description");
    assert.deepEqual(said, ["title", "description"]);
  });

  it("lapses after the idle time and is made again on the next keystroke", () => {
    const { unit, said, clock } = claim();
    unit.focus("title");
    clock.advance(999);
    assert.deepEqual(said, ["title"]);
    clock.advance(1);
    assert.deepEqual(said, ["title", null], "a walked-away tab drops its claim");
    unit.input();
    assert.deepEqual(said, ["title", null, "title"]);
  });

  it("typing keeps the claim alive", () => {
    const { unit, said, clock } = claim();
    unit.focus("title");
    clock.advance(600);
    unit.input();
    clock.advance(600);
    assert.deepEqual(said, ["title"], "restarted by the keystroke");
    clock.advance(400);
    assert.deepEqual(said, ["title", null]);
  });

  it("input with nothing focused says nothing", () => {
    const { unit, said } = claim();
    unit.input();
    assert.deepEqual(said, []);
  });

  it("dispose clears the claim and leaves no timer behind", () => {
    const { unit, said, clock } = claim();
    unit.focus("description");
    unit.dispose();
    assert.deepEqual(said, ["description", null]);
    assert.equal(clock.pending(), 0);
    clock.advance(5000);
    assert.deepEqual(said, ["description", null]);
  });

  it("blur leaves no timer behind either", () => {
    const { unit, clock } = claim();
    unit.focus("title");
    unit.blur();
    assert.equal(clock.pending(), 0);
  });
});
