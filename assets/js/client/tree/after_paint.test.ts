import assert from "node:assert/strict";
import { test } from "node:test";

import type { PaintEnv } from "./after_paint.ts";
import { afterPaint } from "./after_paint.ts";

test("afterPaint runs the work a frame later and then a task later, so a paint lands between", () => {
  const order: string[] = [];
  const env: PaintEnv = {
    frame: (cb) => {
      order.push("frame");
      cb();
    },
    later: (cb) => {
      order.push("later");
      cb();
    },
  };
  afterPaint(() => order.push("work"), env);
  assert.deepEqual(order, ["frame", "later", "work"]);
});

test("afterPaint does nothing until the frame comes", () => {
  let ran = false;
  const env: PaintEnv = { frame: () => {}, later: (cb) => cb() };
  afterPaint(() => (ran = true), env);
  assert.equal(ran, false);
});
