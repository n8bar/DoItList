// Who else is here, and what they have selected (m04.02 item 3.4.2).
//
// The client's copy of one Initiative's `DoItWeb.Presence` topic, kept in the
// shape the server sends it — user id to the metas of every window that user
// has open — and updated the way `Presence.syncDiff` in the `phoenix` package
// updates it, so a diff lands here exactly as it would in the reference
// client. Pure data, no channel: `connection.ts` feeds it and `node --test`
// drives it.
//
// The two selectors at the bottom are `push_presence/1` in
// `initiative_workspace_live.ex`, function for function: everyone else's
// selections, unique per (user, task), and everyone here, self included.

/** One window's entry — `DoItWeb.Presence.selection_meta/2` plus Phoenix's ref. */
export interface PresenceMeta {
  readonly user_id: number;
  readonly task_id: number | null;
  readonly name: string;
  readonly initials: string;
  readonly bg: string;
  readonly fg: string;
  /** Phoenix's per-track ref. Absent only in hand-built test payloads. */
  readonly phx_ref?: string;
}

/** User id (as the server keys it — a string) to that user's open windows. */
export type PresenceState = Readonly<Record<string, readonly PresenceMeta[]>>;

/** Another member's selection, as a row badge needs it. */
export interface Selection {
  readonly user_id: number;
  readonly task_id: number;
  readonly name: string;
  readonly initials: string;
  readonly bg: string;
  readonly fg: string;
}

export const emptyPresence: PresenceState = {};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** One meta, or `null` when the server said something we don't know. */
export function parseMeta(payload: unknown): PresenceMeta | null {
  if (!isRecord(payload)) return null;
  const { user_id: userId, task_id: taskId, name, initials, bg, fg, phx_ref: ref } = payload;
  if (typeof userId !== "number") return null;
  if (typeof taskId !== "number" && taskId !== null && taskId !== undefined) return null;
  if (typeof name !== "string" || typeof initials !== "string") return null;
  if (typeof bg !== "string" || typeof fg !== "string") return null;
  const meta: PresenceMeta = { user_id: userId, task_id: taskId ?? null, name, initials, bg, fg };
  return typeof ref === "string" ? { ...meta, phx_ref: ref } : meta;
}

/**
 * A `{[key]: {metas: [...]}}` block — the whole of `presence_state`, or one
 * side of a `presence_diff`. A meta that cannot be read is dropped; a key with
 * no readable metas is dropped with it.
 */
export function parsePresences(payload: unknown): PresenceState {
  if (!isRecord(payload)) return emptyPresence;
  const out: Record<string, readonly PresenceMeta[]> = {};
  for (const [key, entry] of Object.entries(payload)) {
    if (!isRecord(entry) || !Array.isArray(entry.metas)) continue;
    const metas = entry.metas.map(parseMeta).filter((m): m is PresenceMeta => m !== null);
    if (metas.length > 0) out[key] = metas;
  }
  return out;
}

// What tells two metas apart. Phoenix compares `phx_ref`; a meta without one
// (a test fixture) falls back to what the ref stands for here — the window's
// user and its selection.
const refOf = (meta: PresenceMeta): string => meta.phx_ref ?? `${meta.user_id}:${meta.task_id}`;

/**
 * `presence_state`: the whole topic, replacing what was held. Windows already
 * known keep their place; new ones join after them; anything the server no
 * longer lists is gone — `Presence.syncState`, minus the callbacks.
 */
export function applyState(current: PresenceState, payload: unknown): PresenceState {
  const incoming = parsePresences(payload);
  const next: Record<string, readonly PresenceMeta[]> = {};
  for (const [key, metas] of Object.entries(incoming)) {
    const held = current[key] ?? [];
    const listed = new Set(metas.map(refOf));
    const known = new Set(held.map(refOf));
    next[key] = [
      ...held.filter((meta) => listed.has(refOf(meta))),
      ...metas.filter((meta) => !known.has(refOf(meta))),
    ];
  }
  return next;
}

/**
 * `presence_diff`: joins first, then leaves — `Presence.syncDiff`'s order, which
 * is what makes a selection change (one leave, one join, same user) land as a
 * replacement rather than a flicker. A user whose last window leaves is
 * dropped. The same state comes back when the diff changed nothing.
 */
export function applyDiff(current: PresenceState, payload: unknown): PresenceState {
  if (!isRecord(payload)) return current;
  const joins = parsePresences(payload.joins);
  const leaves = parsePresences(payload.leaves);
  if (Object.keys(joins).length === 0 && Object.keys(leaves).length === 0) return current;

  const next: Record<string, readonly PresenceMeta[]> = { ...current };
  for (const [key, joined] of Object.entries(joins)) {
    // The joined copy of a ref wins, at the end; Phoenix does the same.
    const joinedRefs = new Set(joined.map(refOf));
    next[key] = [...(next[key] ?? []).filter((meta) => !joinedRefs.has(refOf(meta))), ...joined];
  }
  for (const [key, left] of Object.entries(leaves)) {
    const held = next[key];
    if (held === undefined) continue;
    const gone = new Set(left.map(refOf));
    const kept = held.filter((meta) => !gone.has(refOf(meta)));
    if (kept.length === 0) delete next[key];
    else next[key] = kept;
  }
  return next;
}

/**
 * Everyone else's selections — `push_presence/1`'s `selections`. Several
 * windows of the same user on the same task collapse to one badge; my own
 * windows are skipped, because presence marks *other* members' rows.
 */
export function selectionsOf(state: PresenceState, me: number | null): readonly Selection[] {
  const seen = new Set<string>();
  const out: Selection[] = [];
  for (const metas of Object.values(state)) {
    for (const meta of metas) {
      if (meta.user_id === me || meta.task_id === null) continue;
      const key = `${meta.user_id}:${meta.task_id}`;
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({
        user_id: meta.user_id,
        task_id: meta.task_id,
        name: meta.name,
        initials: meta.initials,
        bg: meta.bg,
        fg: meta.fg,
      });
    }
  }
  return out;
}

/** Everyone here, self included — `push_presence/1`'s `online`. */
export function onlineIds(state: PresenceState): ReadonlySet<number> {
  const out = new Set<number>();
  for (const key of Object.keys(state)) {
    const id = Number(key);
    if (Number.isInteger(id)) out.add(id);
  }
  return out;
}
