// The React side of `task_store.ts` (m04.02 item 7.18): one hook per view,
// each a `useSyncExternalStore` over the reader, so a row re-renders when its
// own view's identity changes and not otherwise.

import { useCallback, useSyncExternalStore } from "react";

import type { TreeModel } from "./model.ts";
import type { ChildrenView, RowView, TaskReader } from "./task_store.ts";

/** This row's view, or `null` once its task is gone. */
export function useRow(tasks: TaskReader, id: number): RowView | null {
  const read = useCallback(() => tasks.row(id), [tasks, id]);
  return useSyncExternalStore(tasks.subscribe, read, read);
}

/** One branch's children list — the same object until its order or sort changes. */
export function useChildren(tasks: TaskReader, id: number): ChildrenView {
  const read = useCallback(() => tasks.children(id), [tasks, id]);
  return useSyncExternalStore(tasks.subscribe, read, read);
}

/** The whole model, for the one component that paints all of it (the pane). */
export function useModel(tasks: TaskReader): TreeModel {
  return useSyncExternalStore(tasks.subscribe, tasks.model, tasks.model);
}
