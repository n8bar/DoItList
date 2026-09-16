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
