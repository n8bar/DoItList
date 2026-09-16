// Theme preference for the React client (m04.01 item 2.5).
//
// The SAME semantics as the shared first-paint script in
// `lib/doit_web/components/layouts/theme_script.html.heex`: the preference
// lives in localStorage under `phx:theme`, "system" is stored as *absence*,
// and `<html data-theme>` always carries an explicit light/dark so Tailwind's
// `dark:` variant and daisyUI's vars can never split. The environment is
// injected so this stays pure and unit-testable outside a browser.

export type ThemePreference = "system" | "light" | "dark";
export type ResolvedTheme = "light" | "dark";

export const THEME_KEY = "phx:theme";

export interface ThemeEnv {
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem">;
  root: {
    setAttribute(name: string, value: string): void;
    toggleAttribute(name: string, force?: boolean): boolean;
  };
  prefersDark(): boolean;
}

/** "system" becomes an explicit light/dark; anything unknown is "system". */
export function resolveTheme(theme: ThemePreference, prefersDark: boolean): ResolvedTheme {
  if (theme === "light" || theme === "dark") return theme;
  return prefersDark ? "dark" : "light";
}

/** The saved preference, or "system" when nothing is saved. */
export function currentPreference(env: ThemeEnv): ThemePreference {
  const saved = env.storage.getItem(THEME_KEY);
  return saved === "light" || saved === "dark" ? saved : "system";
}

/** Saves the preference and applies it to the document element. */
export function setTheme(theme: ThemePreference, env: ThemeEnv): ResolvedTheme {
  if (theme === "system") {
    env.storage.removeItem(THEME_KEY);
  } else {
    env.storage.setItem(THEME_KEY, theme);
  }
  const resolved = resolveTheme(theme, env.prefersDark());
  env.root.setAttribute("data-theme", resolved);
  env.root.toggleAttribute("data-theme-system", theme === "system");
  return resolved;
}

/** System → Light → Dark → System, the same order as the LiveView toggle. */
export function nextPreference(theme: ThemePreference): ThemePreference {
  switch (theme) {
    case "system":
      return "light";
    case "light":
      return "dark";
    default:
      return "system";
  }
}

/** The real browser environment. Touches globals only when called. */
export function browserThemeEnv(): ThemeEnv {
  return {
    storage: window.localStorage,
    root: document.documentElement,
    prefersDark: () => window.matchMedia("(prefers-color-scheme: dark)").matches,
  };
}
