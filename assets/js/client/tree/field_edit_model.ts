// One text field of the Details pane while someone else may be writing to it
// (m04.03 4.2, 4.3).
//
// A remote write lands in the record whether or not the user is in the field.
// What the field does with it is decided here, without React or a DOM:
//
//   * untouched (the draft is still what the field started from) — the field
//     takes the new value in place and its baseline moves with it (4.2.1);
//   * dirty — the draft stays exactly as typed, blur still saves it (last
//     writer wins, spec §6), and the incoming value waits under the field with
//     a plain warning (4.2.2). A later remote write replaces the waiting one;
//     one equal to the draft has nothing to warn about; one back to the
//     baseline leaves the server where the user started, so nothing waits;
//   * Cancel (4.3) throws the draft away and adopts the waiting value as both
//     value and baseline. It exists only while something is waiting.
//
// Between focus and change the select-like fields (priority, assignee,
// progress, sort) hold no draft, so for them a remote write is always 4.2.1 —
// the record re-renders the control — and 4.2.2 has nothing to show. Only the
// title and the description run this machine.

/** A value someone else committed while the user's draft differs from it. */
export interface Incoming {
  readonly value: string;
  /** Who did it, for the notice. */
  readonly by: string;
}

export interface FieldEdit {
  /** What the field started from on focus, moved by untouched remote writes. */
  readonly baseline: string;
  /** What the field shows while focused; `null` when it is showing the record. */
  readonly draft: string | null;
  readonly incoming: Incoming | null;
}

export const idle: FieldEdit = { baseline: "", draft: null, incoming: null };

/** The user has typed something other than what they started from. */
export function dirty(state: FieldEdit): boolean {
  return state.draft !== null && state.draft !== state.baseline;
}

/** Cancel is drawn only while a remote value is waiting (4.3). */
export function cancelable(state: FieldEdit): boolean {
  return state.incoming !== null;
}

/** Focus: the record's value becomes the baseline and the draft. A draft already held (a refused edit) is kept. */
export function focus(state: FieldEdit, value: string): FieldEdit {
  return { baseline: value, draft: state.draft ?? value, incoming: null };
}

/** The user typed. Only the draft moves; a waiting value keeps waiting until blur or Cancel. */
export function input(state: FieldEdit, draft: string): FieldEdit {
  if (state.draft === draft) return state;
  const next = { ...state, draft };
  // Typing the incoming value out by hand is the same as taking it.
  if (next.incoming !== null && next.incoming.value === draft) {
    return { baseline: draft, draft, incoming: null };
  }
  return next;
}

/** Someone else's write reached the record while the field is focused. */
export function remote(state: FieldEdit, value: string, by: string): FieldEdit {
  if (state.draft === null) return { ...state, baseline: value, incoming: null };
  if (value === state.baseline) {
    // The server is back to what the user started from: nothing is waiting.
    return state.incoming === null ? state : { ...state, incoming: null };
  }
  if (!dirty(state)) return { baseline: value, draft: value, incoming: null };
  if (value === state.draft) return { baseline: value, draft: value, incoming: null };
  return { ...state, incoming: { value, by } };
}

/** Focus left. The caller commits the draft it held before this; here the field goes back to showing the record. */
export function blur(_state: FieldEdit): FieldEdit {
  return idle;
}

/** Cancel: the draft goes, the waiting value is the field now. Focus stays with the field. */
export function cancel(state: FieldEdit): FieldEdit {
  if (state.incoming === null) return state;
  const value = state.incoming.value;
  return { baseline: value, draft: value, incoming: null };
}

/** The value the control shows. */
export function shownValue(state: FieldEdit, record: string): string {
  return state.draft ?? record;
}

/** The sentence under a dirty field while a remote value waits (4.2.2). */
export function incomingNotice(incoming: Incoming): string {
  return `${incoming.by} changed this to "${incoming.value}" while you were editing. Saving will overwrite it.`;
}

/** Who to name for a remote write: the envelope's actor, or "Someone". */
export function actorName(actor: { name: string; username: string } | null): string {
  if (actor === null) return "Someone";
  return actor.name !== "" ? actor.name : actor.username;
}
