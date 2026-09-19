// The model as each row reads it (m04.02 item 7.18).
//
// A write used to hand the tree context a new model, and a new context
// re-rendered every row — 54 rows for one priority step, ~4ms each. Here the
// model stays where it lives (the domain store) and every row subscribes for
// ITSELF: `row(id)` hands back the same view object until something that row
// paints has changed, and `children(id)` the same list until the order has.
// `useSyncExternalStore` compares snapshots by identity, so a delta touching
// one leaf re-renders that leaf and the ancestors whose roll-up moved, and no
// other row does any work at all.
//
// Nothing is copied: the reader looks at the two sources live — the model,
// and the in-flight marks (pink rows, indeterminate bars, stand-in keys, a
// refused pane edit) — and caches one view per id against their identities.
// The pure model (`model.ts`, `progress.ts`, `row_model.ts`) is untouched;
// this is only the subscription layer.

import type { ProgressCalc, SortMode } from "../api/types.ts";
import type { EditRejection } from "./context.ts";
import type { TaskRecord, TreeModel } from "./model.ts";
import { childIdsOf } from "./model.ts";
import { doneUnitCount, unitCount } from "./progress.ts";
import type { RefPart } from "./row_model.ts";
import { progressValue, refParts } from "./row_model.ts";
import { resolveSort } from "./sort.ts";

/** Anything with `get` and `subscribe` — a store, or a view over one. */
export interface Source<T> {
  get(): T;
  subscribe(listener: () => void): () => void;
}

/** The pending scope and the pane's refusal, as the screen tracks them. */
export interface RowMarks {
  readonly savingIds: ReadonlySet<number>;
  readonly recomputingIds: ReadonlySet<number>;
  /** Server id → the stand-in id its row was first drawn under (item 5.2.2). */
  readonly rowKeys: ReadonlyMap<number, number>;
  readonly rejection: EditRejection | null;
}

export const NO_MARKS: RowMarks = {
  savingIds: new Set<number>(),
  recomputingIds: new Set<number>(),
  rowKeys: new Map<number, number>(),
  rejection: null,
};

/**
 * Everything one row paints from the model. Same object back until it changes.
 * `record.index` and `record.depth` are not kept current here — the label has
 * its own reader (`label(id)`), so a renumbering leaves the row alone (7.21).
 */
export interface RowView {
  readonly record: TaskRecord;
  /** Whether it has children — the order is the children list's business, not the row's. */
  readonly branch: boolean;
  /** `progress_value/1`: the number the bar shows. */
  readonly progress: number;
  /** The unit badge's numbers; `null` on a leaf, which wears none. */
  readonly units: { readonly total: number; readonly done: number } | null;
  readonly calc: ProgressCalc;
  readonly title: readonly RefPart[];
  /** `null` when there is no description to show. */
  readonly description: readonly RefPart[] | null;
  readonly saving: boolean;
  readonly recomputing: boolean;
}

/** One branch's children list. Same object back until the order or sort changes. */
export interface ChildrenView {
  readonly ids: readonly number[];
  readonly sortMode: SortMode;
}

export interface TaskReader {
  /** Fires for any change to the model or the marks; each reader decides for itself. */
  subscribe(listener: () => void): () => void;
  /** The model, live — for event-time reads (a drop, a submit, a reveal). */
  model(): TreeModel;
  rootId(): number;
  calc(): ProgressCalc;
  row(id: number): RowView | null;
  /** The positional label ("3.2.1"), or "" when the style shows none — a string, so a change is one by value (7.21). */
  label(id: number): string;
  children(id: number): ChildrenView;
  /** The React key for `id`'s row: its stand-in id if it was drawn under one. */
  keyOf(id: number): number;
  rejection(): EditRejection | null;
}

const NO_IDS: readonly number[] = [];
const NO_CHILDREN: ChildrenView = { ids: NO_IDS, sortMode: "manual" };

const sameIds = (a: readonly number[], b: readonly number[]): boolean =>
  a === b || (a.length === b.length && a.every((id, i) => id === b[i]));

const sameParts = (a: readonly RefPart[], b: readonly RefPart[]): boolean =>
  a.length === b.length &&
  a.every((part, i) => {
    const other = b[i] as RefPart;
    if (part.kind !== other.kind) return false;
    if (part.kind === "text") return other.kind === "text" && part.text === other.text;
    if (part.kind === "link") return other.kind === "link" && part.id === other.id && part.label === other.label;
    return other.kind === "dead" && part.id === other.id;
  });

const isPlain = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** One level deep: a refetch rebuilds every record, and an unchanged one must still read as unchanged. */
function sameValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (Array.isArray(a) && Array.isArray(b)) return a.length === b.length && a.every((item, i) => Object.is(item, b[i]));
  if (isPlain(a) && isPlain(b)) {
    const keys = Object.keys(a);
    return keys.length === Object.keys(b).length && keys.every((key) => Object.is(a[key], b[key]));
  }
  return false;
}

/**
 * What only the number label paints (7.21). A move to the root's start
 * renumbers every row ("3.2.1" → "4.2.1") and shifts its siblings' slots; the
 * label reads its index through its own subscription and nothing on the row
 * paints the slot or the depth (the row's depth is its branch's prop), so the
 * row's view must not change for them.
 */
const LABEL_KEYS: ReadonlySet<keyof TaskRecord> = new Set<keyof TaskRecord>(["index", "depth", "position"]);

export function sameRecord(a: TaskRecord, b: TaskRecord, ignoring: ReadonlySet<keyof TaskRecord> = LABEL_KEYS): boolean {
  if (a === b) return true;
  const keys = Object.keys(a) as (keyof TaskRecord)[];
  if (keys.length !== Object.keys(b).length) return false;
  return keys.every((key) => ignoring.has(key) || sameValue(a[key], b[key]));
}

function sameRow(a: RowView, b: RowView): boolean {
  return (
    sameRecord(a.record, b.record) &&
    a.branch === b.branch &&
    a.progress === b.progress &&
    (a.units === null ? b.units === null : b.units !== null && a.units.total === b.units.total && a.units.done === b.units.done) &&
    a.calc === b.calc &&
    sameParts(a.title, b.title) &&
    (a.description === null ? b.description === null : b.description !== null && sameParts(a.description, b.description)) &&
    a.saving === b.saving &&
    a.recomputing === b.recomputing
  );
}

function buildRow(model: TreeModel, marks: RowMarks, id: number): RowView | null {
  const record = model.tasks[id];
  if (record === undefined) return null;
  const branch = childIdsOf(model, id).length > 0;
  const description = record.description === null || record.description === "" ? null : refParts(record.description, model);
  return {
    record,
    branch,
    progress: progressValue(model, id),
    units: branch ? { total: unitCount(model, id), done: doneUnitCount(model, id) } : null,
    calc: model.progressCalc,
    title: refParts(record.title, model),
    description,
    saving: marks.savingIds.has(id),
    recomputing: marks.recomputingIds.has(id),
  };
}

interface Cached<V> {
  model: TreeModel | undefined;
  marks: RowMarks;
  view: V;
}

export function createTaskReader(
  modelSource: Source<TreeModel | undefined>,
  marksSource: Source<RowMarks> = { get: () => NO_MARKS, subscribe: () => () => undefined },
): TaskReader {
  const rows = new Map<number, Cached<RowView | null>>();
  const lists = new Map<number, Cached<ChildrenView>>();

  // The last model seen, for `model()` on the render that unmounts the tree:
  // the screen forgets a tree it may no longer show, and a row's subscription
  // reads once more before React takes it down.
  let lastModel: TreeModel | undefined;
  const current = () => {
    const model = modelSource.get();
    if (model !== undefined) lastModel = model;
    return { model, marks: marksSource.get() };
  };

  /** The cached view when its inputs are the current ones; else a fresh one, or the old one if nothing it holds changed. */
  const read = <V>(
    cache: Map<number, Cached<V>>,
    id: number,
    build: (model: TreeModel, marks: RowMarks) => V,
    empty: V,
    same: (a: V, b: V) => boolean,
  ): V => {
    const { model, marks } = current();
    const held = cache.get(id);
    if (held !== undefined && held.model === model && held.marks === marks) return held.view;
    const fresh = model === undefined ? empty : build(model, marks);
    const view = held !== undefined && same(held.view, fresh) ? held.view : fresh;
    cache.set(id, { model, marks, view });
    return view;
  };

  return {
    subscribe(listener) {
      const offModel = modelSource.subscribe(listener);
      const offMarks = marksSource.subscribe(listener);
      return () => {
        offModel();
        offMarks();
      };
    },
    model() {
      const model = current().model ?? lastModel;
      if (model === undefined) throw new Error("the tree's model was never read");
      return model;
    },
    rootId: () => modelSource.get()?.rootId ?? 0,
    calc: () => modelSource.get()?.progressCalc ?? "leaf_average",
    row: (id) =>
      read(
        rows,
        id,
        (model, marks) => buildRow(model, marks, id),
        null,
        (a, b) => (a === null ? b === null : b !== null && sameRow(a, b)),
      ),
    label: (id) => modelSource.get()?.tasks[id]?.index ?? lastModel?.tasks[id]?.index ?? "",
    children: (id) =>
      read(
        lists,
        id,
        (model) => ({ ids: childIdsOf(model, id), sortMode: resolveSort(model, id)[0] }),
        NO_CHILDREN,
        (a, b) => a.sortMode === b.sortMode && sameIds(a.ids, b.ids),
      ),
    keyOf: (id) => marksSource.get().rowKeys.get(id) ?? id,
    rejection: () => marksSource.get().rejection,
  };
}
