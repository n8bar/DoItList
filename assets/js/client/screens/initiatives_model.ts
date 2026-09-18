// The Initiatives index, decided without a DOM (m04.02 items 4.1–4.3).
//
// A port of the LiveView index's rules — `sort_initiatives/2`, the card's
// "Updated" line, the percent on the bar, `role_badge_class/1` — so the two
// pages order and label the same list the same way. Everything here is a pure
// function over `InitiativeSummary` rows; `initiatives.tsx` only draws it.
//
// The sort choice is the LiveView's shape too: one mode plus a per-mode
// reverse flag (`index_sort_reverse_by_mode`). The server keeps that on the
// account preferences, but the client API has no write for it yet, so this
// client keeps it in `localStorage` — the same place the tree keeps which
// branches are open. Items 4.4 (drag) and 4.6 (live changes) build on
// `sortInitiatives` and `manualOrder` rather than on the screen.

import type {
  ArchivedInitiative,
  InitiativeArchive,
  InitiativeSummary,
  Role,
  TrashedInitiative,
} from "../api/types.ts";
import type { KeyValueStore } from "../storage/last_user.ts";

/**
 * The Sort control's options, in the order the template lists them. `""` is
 * "Recent": the server's own order (owners' Initiatives first, then most
 * recently updated), left exactly as it arrived.
 */
export const SORT_MODES = ["", "manual", "name", "progress", "created", "updated"] as const;

export type IndexSortMode = (typeof SORT_MODES)[number];

export const SORT_OPTIONS: readonly { value: IndexSortMode; label: string }[] = [
  { value: "", label: "Recent" },
  { value: "manual", label: "Manual" },
  { value: "name", label: "Name" },
  { value: "progress", label: "Progress" },
  { value: "created", label: "Created" },
  { value: "updated", label: "Updated" },
];

export interface IndexSortState {
  readonly mode: IndexSortMode;
  /** Reverse, remembered per mode, as the LiveView's preferences keep it. */
  readonly reverseByMode: Readonly<Partial<Record<IndexSortMode, boolean>>>;
}

export const initialSortState: IndexSortState = { mode: "", reverseByMode: {} };

export function isSortMode(value: unknown): value is IndexSortMode {
  return typeof value === "string" && (SORT_MODES as readonly string[]).includes(value);
}

/** Whether the current mode is reversed. */
export function reversed(state: IndexSortState): boolean {
  return state.reverseByMode[state.mode] === true;
}

/** A new mode picked from the select. Its own reverse flag comes with it. */
export function withMode(state: IndexSortState, mode: IndexSortMode): IndexSortState {
  return state.mode === mode ? state : { ...state, mode };
}

/** The Reverse box ticked or cleared, for the current mode only. */
export function withReverse(state: IndexSortState, reverse: boolean): IndexSortState {
  if (reversed(state) === reverse) return state;
  return { ...state, reverseByMode: { ...state.reverseByMode, [state.mode]: reverse } };
}

/**
 * The saved manual order: the ids of every row this user has dragged into a
 * position, in that order. A row never dragged has `sort_order: null` and is
 * not part of the order; `sortInitiatives` puts those after the ordered ones,
 * as `stored_order/1` on the server does.
 */
export function manualOrder(rows: readonly InitiativeSummary[]): number[] {
  return rows
    .filter((row) => row.sort_order !== null)
    .sort((a, b) => (a.sort_order as number) - (b.sort_order as number))
    .map((row) => row.id);
}

type Key = string | number;

function sortKey(row: InitiativeSummary, mode: IndexSortMode): Key {
  switch (mode) {
    case "name":
      return (row.name ?? "").toLowerCase();
    case "progress":
      return row.progress ?? 0;
    case "created":
      return row.created_at;
    case "updated":
      return row.updated_at;
    default:
      return 0;
  }
}

function compareKeys(a: Key, b: Key): number {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

/**
 * The list in the order the page shows it. Mirrors `sort_initiatives/2`: the
 * empty mode keeps the server's order; `manual` follows the saved order with
 * un-dragged rows last, in server order; the rest sort ascending by their key.
 * Reverse flips the whole result, whatever the mode. Ties keep server order.
 * ISO-8601 UTC timestamps compare correctly as strings, so the dates need no
 * parsing.
 */
export function sortInitiatives(
  rows: readonly InitiativeSummary[],
  state: IndexSortState,
): InitiativeSummary[] {
  let sorted: InitiativeSummary[];

  if (state.mode === "") {
    sorted = [...rows];
  } else if (state.mode === "manual") {
    const order = manualOrder(rows);
    const position = new Map(order.map((id, index) => [id, index]));
    const last = order.length;
    sorted = [...rows].sort(
      (a, b) => (position.get(a.id) ?? last) - (position.get(b.id) ?? last),
    );
  } else {
    const mode = state.mode;
    sorted = [...rows].sort((a, b) => compareKeys(sortKey(a, mode), sortKey(b, mode)));
  }

  return reversed(state) ? sorted.reverse() : sorted;
}

/** The percent on the bar, and its `aria-valuenow`. A missing value reads as 0. */
export function progressValue(progress: number | null | undefined): number {
  return typeof progress === "number" && Number.isFinite(progress) ? progress : 0;
}

export function percentText(progress: number | null | undefined): string {
  return `${progressValue(progress)}%`;
}

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

/**
 * The card's "Updated Sep 17, 2026" line — the template's `%b %-d, %Y` in the
 * viewer's local time, as `<.local_time>` renders it. An unreadable timestamp
 * gives an empty string rather than "Invalid Date" on a card.
 */
export function updatedText(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return `Updated ${MONTHS[date.getMonth()]} ${date.getDate()}, ${date.getFullYear()}`;
}

/** The subtitle line, or `null` when it is blank (the server stores a space). */
export function subtitleText(row: Pick<InitiativeSummary, "subtitle">): string | null {
  if (typeof row.subtitle !== "string") return null;
  const trimmed = row.subtitle.trim();
  return trimmed === "" ? null : trimmed;
}

/** The description line, or `null` when there is nothing to say. */
export function descriptionText(row: Pick<InitiativeSummary, "description">): string | null {
  if (typeof row.description !== "string") return null;
  return row.description.trim() === "" ? null : row.description;
}

/** `role_badge_class/1`, word for word. Any role but owner or editor is grey. */
export function roleBadgeClass(role: Role | string): string {
  switch (role) {
    case "owner":
      return "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/40 dark:text-emerald-300";
    case "editor":
      return "bg-blue-100 text-blue-800 dark:bg-blue-900/40 dark:text-blue-300";
    default:
      return "bg-zinc-100 text-zinc-700 dark:bg-zinc-800 dark:text-zinc-300";
  }
}

// --- Remembering the sort choice ------------------------------------------

export const SORT_STORAGE_KEY = "doit:index_sort";

/** The remembered sort, or the default where nothing usable is stored. */
export function readSortState(store: KeyValueStore | null): IndexSortState {
  if (store === null) return initialSortState;
  try {
    const raw = store.getItem(SORT_STORAGE_KEY);
    if (raw === null) return initialSortState;
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) return initialSortState;
    const source = parsed as Record<string, unknown>;
    const mode = isSortMode(source["mode"]) ? source["mode"] : "";
    const reverseByMode: Partial<Record<IndexSortMode, boolean>> = {};
    const flags = source["reverseByMode"];
    if (typeof flags === "object" && flags !== null) {
      for (const [key, value] of Object.entries(flags as Record<string, unknown>)) {
        if (isSortMode(key) && value === true) reverseByMode[key] = true;
      }
    }
    return { mode, reverseByMode };
  } catch {
    return initialSortState;
  }
}

export function writeSortState(store: KeyValueStore | null, state: IndexSortState): void {
  if (store === null) return;
  try {
    store.setItem(SORT_STORAGE_KEY, JSON.stringify(state));
  } catch {
    // A full or blocked localStorage costs the memory of the choice, not the sort.
  }
}

// --- Dragging to reorder ----------------------------------------------------
//
// The `InitiativeDrag` hook's drop arithmetic, without the DOM: which side of
// the card under the pointer the row lands on, the list that results, and what
// to tell the server. The hook reads the new order off the cards and pushes
// the whole list; here the same order is decided from ids, and the server is
// told the one slot (`update initiative {position}`), which it turns into the
// same whole-list write.

export type DropSide = "before" | "after";

/** The hook's midline rule: below the card's middle is "after". */
export function dropSide(top: number, height: number, y: number): DropSide {
  return y > top + height / 2 ? "after" : "before";
}

/**
 * The shown ids after `sourceId` is dropped on the given side of `targetId`.
 * `null` when nothing would move — onto itself, an unknown card, or the slot
 * it already holds — so no write goes out for a drop that changes nothing.
 */
export function droppedOrder(
  shown: readonly number[],
  sourceId: number,
  targetId: number,
  side: DropSide,
): number[] | null {
  if (sourceId === targetId || !shown.includes(sourceId) || !shown.includes(targetId)) return null;
  const next = shown.filter((id) => id !== sourceId);
  const at = next.indexOf(targetId) + (side === "after" ? 1 : 0);
  next.splice(at, 0, sourceId);
  return next.every((id, index) => id === shown[index]) ? null : next;
}

/**
 * The order to store behind what is shown. A drop lands the list in Manual;
 * with Manual's Reverse on, the page shows the stored order backwards, so the
 * stored list is the shown one reversed — the card stays where it was dropped.
 */
export function storedOrder(shown: readonly number[], manual: IndexSortState): number[] {
  return reversed(manual) ? [...shown].reverse() : [...shown];
}

/** Every row's `sort_order` set to its slot in `order`; rows not listed keep theirs. */
export function applyOrder(
  rows: readonly InitiativeSummary[],
  order: readonly number[],
): InitiativeSummary[] {
  const slot = new Map(order.map((id, index) => [id, index]));
  return rows.map((row) => {
    const next = slot.get(row.id);
    return next === undefined || next === row.sort_order ? row : { ...row, sort_order: next };
  });
}

/** The `sort_order` each row had in `prior`, put back — the revert on a refused write. */
export function revertOrder(
  rows: readonly InitiativeSummary[],
  prior: readonly InitiativeSummary[],
): InitiativeSummary[] {
  const was = new Map(prior.map((row) => [row.id, row.sort_order]));
  return rows.map((row) => {
    const back = was.get(row.id);
    return back === undefined || back === row.sort_order ? row : { ...row, sort_order: back };
  });
}

/** The `update initiative {position}` operation for one dropped row. */
export function positionRequest(
  id: number,
  position: number,
): {
  operations: { op: "update"; type: "initiative"; id: number; data: { position: number } }[];
} {
  return { operations: [{ op: "update", type: "initiative", id, data: { position } }] };
}

// --- New Initiative ---------------------------------------------------------

export interface NewInitiativeValues extends Record<string, string | boolean> {
  name: string;
  description: string;
}

/** The `add initiative` operation, as `POST /app/api/operations` takes it. */
export function newInitiativeRequest(values: NewInitiativeValues): {
  operations: { op: "add"; type: "initiative"; data: Record<string, string> }[];
} {
  const data: Record<string, string> = { name: values.name.trim() };
  const description = values.description.trim();
  if (description !== "") data["description"] = description;
  return { operations: [{ op: "add", type: "initiative", data }] };
}

/** The batch reply's first result: the row the engine just created. */
export interface AddInitiativeResult {
  id: number;
  type: "initiative";
  name: string;
  root_task_id: number;
  version: number;
}

export function createdInitiative(payload: unknown): AddInitiativeResult | null {
  if (typeof payload !== "object" || payload === null) return null;
  const results = (payload as { results?: unknown }).results;
  if (!Array.isArray(results) || results.length === 0) return null;
  const first = results[0] as { id?: unknown; type?: unknown; data?: unknown };
  const data = (typeof first.data === "object" && first.data !== null ? first.data : {}) as {
    name?: unknown;
    root_task_id?: unknown;
    version?: unknown;
  };
  if (typeof first.id !== "number" || first.type !== "initiative") return null;
  return {
    id: first.id,
    type: "initiative",
    name: typeof data.name === "string" ? data.name : "",
    root_task_id: typeof data.root_task_id === "number" ? data.root_task_id : 0,
    version: typeof data.version === "number" ? data.version : 1,
  };
}

/**
 * The index row for an Initiative this user just created, so it is on the
 * list the moment the server confirms it, without a second read. Owner, at
 * zero, with no tasks yet — which is what the server would say.
 */
export function summaryForCreated(
  created: AddInitiativeResult,
  values: NewInitiativeValues,
  now: string,
): InitiativeSummary {
  const description = values.description.trim();
  return {
    id: created.id,
    name: created.name === "" ? values.name.trim() : created.name,
    subtitle: "",
    description: description === "" ? null : description,
    role: "owner",
    progress: 0,
    unit_count: 0,
    root_task_id: created.root_task_id,
    version: created.version,
    sort_order: null,
    archived: false,
    created_at: now,
    updated_at: now,
  };
}

// --- The Archived and Trash drawer -----------------------------------------
//
// The index footer's rules (m04.02 item 4.5), ported from `visible_archived/2`
// and `archive_drawer_title/3`: which put-away rows show, what the summary
// line counts, which buttons a row offers, and what the list looks like the
// moment a Restore is pressed — before the server has answered.

/** `visible_archived/2`: archived rows always; a purely hidden row only under Show hidden. */
export function visibleArchived(
  rows: readonly ArchivedInitiative[],
  showHidden: boolean,
): ArchivedInitiative[] {
  return rows.filter((row) => row.archived || (row.hidden && showHidden));
}

/** Whether the Show hidden box appears: only when something is hidden. */
export function hasHidden(rows: readonly ArchivedInitiative[]): boolean {
  return rows.some((row) => row.hidden);
}

/**
 * `archive_drawer_title/3`: "Archived (n) · Trash (n)", each part only when
 * its bucket has rows. Archived counts what Show hidden lets through; Trash
 * counts everything it holds, whether or not Show trash is on.
 */
export function archiveDrawerTitle(archive: InitiativeArchive, showHidden: boolean): string {
  const parts: string[] = [];
  if (archive.archived.length > 0) {
    parts.push(`Archived (${visibleArchived(archive.archived, showHidden).length})`);
  }
  if (archive.trashed.length > 0) parts.push(`Trash (${archive.trashed.length})`);
  return parts.join(" · ");
}

/** The drawer is drawn at all only when it has something to show. */
export function archiveHasRows(archive: InitiativeArchive | null): archive is InitiativeArchive {
  return archive !== null && (archive.archived.length > 0 || archive.trashed.length > 0);
}

export type ArchiveAction = "restore" | "unhide";

/** An Archived row's buttons: Restore while archived, Unhide while hidden — both when both. */
export function archivedRowActions(row: ArchivedInitiative): ArchiveAction[] {
  const actions: ArchiveAction[] = [];
  if (row.archived) actions.push("restore");
  if (row.hidden) actions.push("unhide");
  return actions;
}

/**
 * A Trash row's buttons. Only the owner may restore, and the API has no
 * permanent delete, so there is no Delete button here yet.
 */
export function trashedRowActions(row: TrashedInitiative): ArchiveAction[] {
  return row.role === "owner" ? ["restore"] : [];
}

/** The `update initiative {state}` operation each drawer button posts. */
export type InitiativeState = "unarchived" | "unhidden" | "restored";

export function stateRequest(
  id: number,
  state: InitiativeState,
): {
  operations: { op: "update"; type: "initiative"; id: number; data: { state: InitiativeState } }[];
} {
  return { operations: [{ op: "update", type: "initiative", id, data: { state } }] };
}

/** The row's "trashed Sep 17" line — the template's `%b %-d` in local time. */
export function trashedText(iso: string): string {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return "";
  return `trashed ${MONTHS[date.getMonth()]} ${date.getDate()}`;
}

/** The index row a put-away Initiative becomes once nothing holds it back. */
function summaryOf(row: ArchivedInitiative | TrashedInitiative): InitiativeSummary {
  const { hidden: _hidden, ...rest } = row as TrashedInitiative;
  const { trashed_at: _trashedAt, ...summary } = rest;
  return { ...summary, archived: false };
}

export interface ArchiveStep {
  /** The drawer after the press. */
  readonly archive: InitiativeArchive;
  /** The row to add to the index, when the press frees it entirely. */
  readonly joined: InitiativeSummary | null;
  /** What to post. */
  readonly state: InitiativeState;
}

/**
 * What one drawer button does to the drawer, decided before the server answers
 * (§6.2). Restore on an Archived row clears `archived`, Unhide clears `hidden`;
 * a row with neither flag left leaves the drawer and joins the index. Restore
 * on a Trash row takes it out of Trash and onto the index. `null` when the row
 * is not there to act on.
 */
export function archiveStep(
  archive: InitiativeArchive,
  bucket: "archived" | "trashed",
  id: number,
  action: ArchiveAction,
): ArchiveStep | null {
  if (bucket === "trashed") {
    const row = archive.trashed.find((item) => item.id === id);
    if (row === undefined || action !== "restore") return null;
    return {
      archive: { ...archive, trashed: archive.trashed.filter((item) => item.id !== id) },
      joined: summaryOf(row),
      state: "restored",
    };
  }

  const row = archive.archived.find((item) => item.id === id);
  if (row === undefined) return null;
  const next: ArchivedInitiative =
    action === "restore" ? { ...row, archived: false } : { ...row, hidden: false };
  const stays = next.archived || next.hidden;
  return {
    archive: {
      ...archive,
      archived: stays
        ? archive.archived.map((item) => (item.id === id ? next : item))
        : archive.archived.filter((item) => item.id !== id),
    },
    joined: stays ? null : summaryOf(row),
    state: action === "restore" ? "unarchived" : "unhidden",
  };
}

/** The index with one freed row added at the top, where a new row lands too. */
export function withJoined(
  rows: readonly InitiativeSummary[],
  joined: InitiativeSummary,
): InitiativeSummary[] {
  return [joined, ...rows.filter((row) => row.id !== joined.id)];
}

/** The index without the row a refused restore had put there. */
export function withoutJoined(
  rows: readonly InitiativeSummary[],
  id: number,
): InitiativeSummary[] {
  return rows.filter((row) => row.id !== id);
}
