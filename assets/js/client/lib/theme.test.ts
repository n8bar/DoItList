import { strict as assert } from "node:assert";
import { test } from "node:test";

import type { ThemeEnv } from "./theme.ts";
import { currentPreference, resolveTheme, setTheme, THEME_KEY } from "./theme.ts";

function fakeEnv(saved: string | null = null, prefersDark = false) {
  const store = new Map<string, string>();
  if (saved !== null) store.set(THEME_KEY, saved);
  const attributes = new Map<string, string>();
  const flags = new Map<string, boolean>();

  const env: ThemeEnv = {
    storage: {
      getItem: (key) => store.get(key) ?? null,
      setItem: (key, value) => void store.set(key, value),
      removeItem: (key) => void store.delete(key),
    },
    root: {
      setAttribute: (name, value) => void attributes.set(name, value),
      toggleAttribute: (name, force) => {
        flags.set(name, Boolean(force));
        return Boolean(force);
      },
    },
    prefersDark: () => prefersDark,
  };

  return { env, store, attributes, flags };
}

test("resolveTheme keeps explicit themes and resolves system", () => {
  assert.equal(resolveTheme("light", true), "light");
  assert.equal(resolveTheme("dark", false), "dark");
  assert.equal(resolveTheme("system", true), "dark");
  assert.equal(resolveTheme("system", false), "light");
});

test("currentPreference reads the saved value, defaulting to system", () => {
  assert.equal(currentPreference(fakeEnv("dark").env), "dark");
  assert.equal(currentPreference(fakeEnv(null).env), "system");
  assert.equal(currentPreference(fakeEnv("nonsense").env), "system");
});

test("setTheme stores an explicit theme and applies it", () => {
  const { env, store, attributes, flags } = fakeEnv(null, true);
  assert.equal(setTheme("light", env), "light");
  assert.equal(store.get(THEME_KEY), "light");
  assert.equal(attributes.get("data-theme"), "light");
  assert.equal(flags.get("data-theme-system"), false);
});

test("setTheme stores system as absence and resolves against the OS", () => {
  const { env, store, attributes, flags } = fakeEnv("dark", true);
  assert.equal(setTheme("system", env), "dark");
  assert.equal(store.has(THEME_KEY), false);
  assert.equal(attributes.get("data-theme"), "dark");
  assert.equal(flags.get("data-theme-system"), true);
});
