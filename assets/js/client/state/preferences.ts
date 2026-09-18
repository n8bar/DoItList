// Preference state: choices the user made and expects to keep (m04.01 item 3.1).
//
// The lifetime test (guardrails §7.3) is what separates this from `ui.ts`: a
// collapsed pane is forgotten on reload and lives in `ui`; "show archived
// Initiatives" is a decision the user made about their account and should still
// be true tomorrow, so it lives here.
//
// `theme` is persisted by `lib/theme.ts`, into the same `phx:theme` key the
// LiveView and the first-paint script use, so the two clients can't disagree
// about the user's theme; `touch` likewise by `lib/touch.ts` (`phx:touch`,
// m04.02 7.8) — a device choice, never the account's. `rows` and `indexSort` are the account's, read from
// `GET /app/api/session` at boot; the index sort is the one the client writes
// back (`update account`, m04.02 7.3). The view preferences below are
// per-account server state in a later arc; holding them here now means the
// screens read them from one place either way.

import type { ThemePreference } from "../lib/theme.ts";
import type { IndexSortState } from "../screens/initiatives_model.ts";
import { initialSortState } from "../screens/initiatives_model.ts";
import type { Store } from "./store.ts";
import { createStore } from "./store.ts";

export interface ViewPreferences {
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
  /** The touch layout (7.8): a 44×44 tap on the tree's box and chevron. */
  readonly touch: boolean;
  readonly view: ViewPreferences;
  readonly rows: RowPreferences;
  /** The Initiatives index's Sort and Reverse choice, as the account saved it (7.3). */
  readonly indexSort: IndexSortState;
}

export const initialViewPreferences: ViewPreferences = {
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
  touch: false,
  view: initialViewPreferences,
  rows: initialRowPreferences,
  indexSort: initialSortState,
};

export type PreferencesStore = Store<PreferencesState>;

export function createPreferencesStore(initial: Partial<PreferencesState> = {}): PreferencesStore {
  return createStore<PreferencesState>({ ...initialPreferencesState, ...initial });
}

export function setThemePreference(store: PreferencesStore, theme: ThemePreference): void {
  store.set((state) => (state.theme === theme ? state : { ...state, theme }));
}

export function setTouchPreference(store: PreferencesStore, touch: boolean): void {
  store.set((state) => (state.touch === touch ? state : { ...state, touch }));
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

/** Files the index sort — off the session read, a change the user just made, or a reply. */
export function setIndexSort(store: PreferencesStore, indexSort: IndexSortState): void {
  store.set((state) => (state.indexSort === indexSort ? state : { ...state, indexSort }));
}
