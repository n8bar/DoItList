// Which task is selected, and which one was (m04.02 item 2.2.3).
//
// Two rules that look small and are not:
//
//   * Enter with nothing selected reopens the LAST TASK — the one the user was
//     just on, which is what the shortcut list promises and what the LiveView
//     answers from `DoitSelection.lastId` (`…live.ex:3329`). Not the last row in
//     the tree, which is where the bottom of a long Initiative is.
//   * A selection that is no longer on screen is dropped — but not before the
//     screen has settled. The deep link expands ancestors a moment after the
//     first paint, and clearing the selection in between would undo the reveal
//     the user followed the link for.

/**
 * The selection as a row reads it: the current id, and a way to hear it
 * change. Each row subscribes for itself, so a selection change re-renders
 * the row that lost it and the row that got it — not the tree.
 */
export interface Selected {
  get(): number | null;
  subscribe(listener: () => void): () => void;
}

/** A `Selected` over any store that holds `selectedTaskId`. */
export function selectionOf<T extends { readonly selectedTaskId: number | null }>(store: {
  get(): T;
  subscribe(listener: () => void): () => void;
}): Selected {
  return {
    get: () => store.get().selectedTaskId,
    subscribe: (listener) => store.subscribe(listener),
  };
}

/**
 * What a click on row `id` selects: the row — or nothing, when it is the
 * selected row already. The workspace's row click toggles the same way
 * (`DoitSelection.clear()` on a second click); a pill click never clears.
 */
export function clickedSelection(selectedId: number | null, id: number): number | null {
  return selectedId === id ? null : id;
}

export interface SelectionState {
  readonly selectedId: number | null;
  /** The last task actually selected. Survives a clear; that is its whole job. */
  readonly lastSelectedId: number | null;
}

export const noSelection: SelectionState = { selectedId: null, lastSelectedId: null };

/** Selects `id` — or clears, which remembers rather than forgets. */
export function rememberSelection(state: SelectionState, id: number | null): SelectionState {
  if (state.selectedId === id) return state;
  return { selectedId: id, lastSelectedId: id ?? state.lastSelectedId };
}

/**
 * The selection to keep. `settled` is false until the deep link has had its
 * chance to expand the branch the selected task lives in.
 */
export function keptSelection(
  selectedId: number | null,
  visible: readonly number[],
  settled: boolean,
): number | null {
  if (selectedId === null) return null;
  if (!settled) return selectedId;
  return visible.includes(selectedId) ? selectedId : null;
}

/**
 * Forgets a remembered task that is not in the tree any more — a collaborator
 * deleted it and the refetch dropped it, or it belongs to the Initiative the
 * user came from. Enter with nothing selected then falls back to the first
 * visible row, as the workspace does when `DoitSelection.lastId` names a row
 * that is no longer there (`…live.ex:3338`), instead of selecting a ghost and
 * appearing to do nothing.
 */
export function forgetMissing(
  state: SelectionState,
  exists: (id: number) => boolean,
): SelectionState {
  const id = state.lastSelectedId;
  if (id === null || exists(id)) return state;
  return { selectedId: state.selectedId, lastSelectedId: null };
}

/**
 * Which of the branches a reveal asked to open are still closed.
 *
 * Opening them is a state change, so the list of visible rows only catches up on
 * the next render — and in between, the task the link named is still buried.
 * Pruning then reads a tree that does not contain it yet and clears the
 * selection the reveal had just made. So pruning waits for this to come back
 * empty.
 */
export function stillClosed(
  expanding: readonly number[],
  collapsed: (id: number) => boolean,
): readonly number[] {
  return expanding.filter(collapsed);
}
