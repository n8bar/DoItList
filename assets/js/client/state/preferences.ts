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

/**
 * Which attributes a task row shows — the account's "Task attributes shown on
 * rows" choices (m02.04 §2.4), mirroring the LiveView's `@display` map so the
 * two trees honour one set of names. Server state, read once at boot from
 * `GET /app/api/session`; the account page is still where they are changed.
 */
export interface RowPreferences {
  readonly priority: boolean;
  readonly assignee: boolean;
  /** The completion checkbox and the progress bar, as one element. */
  readonly progress: boolean;
  /** The chevron's leaf / child count badge. */
  readonly count: boolean;
}

export interface PreferencesState {
  readonly theme: ThemePreference;
  readonly view: ViewPreferences;
  readonly rows: RowPreferences;
}

export const initialViewPreferences: ViewPreferences = {
  initiativeSort: "manual",
  showArchived: false,
  showCompleted: true,
};

/** The server's defaults (`DoIt.Accounts.UserPreferences`): everything shown. */
export const initialRowPreferences: RowPreferences = {
  priority: true,
  assignee: true,
  progress: true,
  count: true,
};

export const initialPreferencesState: PreferencesState = {
  theme: "system",
  view: initialViewPreferences,
  rows: initialRowPreferences,
};

export type PreferencesStore = Store<PreferencesState>;

export function createPreferencesStore(initial: Partial<PreferencesState> = {}): PreferencesStore {
  return createStore<PreferencesState>({ ...initialPreferencesState, ...initial });
}

export function setThemePreference(store: PreferencesStore, theme: ThemePreference): void {
  store.set((state) => (state.theme === theme ? state : { ...state, theme }));
}

/**
 * The session read's `preferences` object, as row preferences. Defensive on
 * purpose: a field the server did not send, or sent as something other than a
 * boolean, falls back to the default rather than hiding part of a row. A
 * preference is not worth a failed boot.
 */
export function rowPreferencesFrom(payload: unknown): RowPreferences {
  if (typeof payload !== "object" || payload === null) return initialRowPreferences;
  const source = payload as Record<string, unknown>;
  const flag = (key: string, fallback: boolean): boolean => {
    const value = source[key];
    return typeof value === "boolean" ? value : fallback;
  };
  return {
    priority: flag("show_task_priority", initialRowPreferences.priority),
    assignee: flag("show_task_assignee", initialRowPreferences.assignee),
    progress: flag("show_task_progress", initialRowPreferences.progress),
    count: flag("show_task_count", initialRowPreferences.count),
  };
}

/** Files the row preferences the session read carried. */
export function setRowPreferences(store: PreferencesStore, rows: RowPreferences): void {
  store.set((state) => {
    const same =
      state.rows.priority === rows.priority &&
      state.rows.assignee === rows.assignee &&
      state.rows.progress === rows.progress &&
      state.rows.count === rows.count;
    return same ? state : { ...state, rows };
  });
}
