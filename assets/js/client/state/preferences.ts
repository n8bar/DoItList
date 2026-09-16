// Preference state: choices the user made and expects to keep (m04.01 item 3.1).
//
// The lifetime test (guardrails §7.3) is what separates this from `ui.ts`: a
// collapsed pane is forgotten on reload and lives in `ui`; "show archived
// Initiatives" is a decision the user made about their account and should still
// be true tomorrow, so it lives here.
//
// Only `theme` is actually persisted today — by `lib/theme.ts`, into the same
// `phx:theme` key the LiveView and the first-paint script use, so the two
// clients can't disagree about the user's theme. The view preferences below are
// per-account server state in a later arc; holding them here now means the
// screens read them from one place either way.

import type { ThemePreference } from "../lib/theme.ts";
import type { Store } from "./store.ts";
import { createStore } from "./store.ts";

export type InitiativeSort = "manual" | "name" | "progress" | "updated";

export interface ViewPreferences {
  /** How the Initiatives index is ordered. */
  readonly initiativeSort: InitiativeSort;
  /** Whether archived Initiatives appear in the index. */
  readonly showArchived: boolean;
  /** Whether completed tasks appear in a tree. Arc 2 reads this. */
  readonly showCompleted: boolean;
}

export interface PreferencesState {
  readonly theme: ThemePreference;
  readonly view: ViewPreferences;
}

export const initialViewPreferences: ViewPreferences = {
  initiativeSort: "manual",
  showArchived: false,
  showCompleted: true,
};

export const initialPreferencesState: PreferencesState = {
  theme: "system",
  view: initialViewPreferences,
};

export type PreferencesStore = Store<PreferencesState>;

export function createPreferencesStore(initial: Partial<PreferencesState> = {}): PreferencesStore {
  return createStore<PreferencesState>({ ...initialPreferencesState, ...initial });
}

export function setThemePreference(store: PreferencesStore, theme: ThemePreference): void {
  store.set((state) => (state.theme === theme ? state : { ...state, theme }));
}
