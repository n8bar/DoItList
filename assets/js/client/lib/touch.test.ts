import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { TouchEnv } from "./touch.ts";
import { currentTouch, resolveTouch, setTouch, TOUCH_KEY } from "./touch.ts";

function fakeEnv(saved: string | null = null, coarsePointer = false) {
  const store = new Map<string, string>();
  if (saved !== null) store.set(TOUCH_KEY, saved);
  const flags = new Map<string, boolean>();

  const env: TouchEnv = {
    storage: {
      getItem: (key) => store.get(key) ?? null,
      setItem: (key, value) => void store.set(key, value),
      removeItem: (key) => void store.delete(key),
    },
    root: {
      toggleAttribute: (name, force) => {
        flags.set(name, Boolean(force));
        return Boolean(force);
      },
    },
    coarsePointer: () => coarsePointer,
  };

  return { env, store, flags };
}

test("resolveTouch honours a saved choice and otherwise follows the pointer", () => {
  assert.equal(resolveTouch("on", false), true);
  assert.equal(resolveTouch("off", true), false);
  assert.equal(resolveTouch(null, true), true);
  assert.equal(resolveTouch(null, false), false);
  assert.equal(resolveTouch("garbage", true), true);
});

test("currentTouch reads the device's saved choice; a first visit follows (pointer: coarse)", () => {
  assert.equal(currentTouch(fakeEnv("on").env), true);
  assert.equal(currentTouch(fakeEnv("off", true).env), false);
  assert.equal(currentTouch(fakeEnv(null, true).env), true);
  assert.equal(currentTouch(fakeEnv(null, false).env), false);
});

test("setTouch saves on the device and flips data-touch on the root", () => {
  const { env, store, flags } = fakeEnv(null, false);
  setTouch(true, env);
  assert.equal(store.get(TOUCH_KEY), "on");
  assert.equal(flags.get("data-touch"), true);
  setTouch(false, env);
  assert.equal(store.get(TOUCH_KEY), "off");
  assert.equal(flags.get("data-touch"), false);
});

test("the key is the one the first-paint script reads", () => {
  assert.equal(TOUCH_KEY, "phx:touch");
});
