// Positional task labels, client-side (m04.02 item 1.1.4).
//
// A port of `DoIt.Tasks.Index.label/2`, rule for rule. The label is derived
// purely from a node's zero-based sibling position at every level, so it is
// automatically right after any reorder or move — nothing is stored, nothing
// needs fixing up.
//
// `relabel/2` is the reason this is a module of its own: only the sibling run
// whose positions actually changed, and the subtrees under it, are structurally
// stale. Every other record keeps its identity, so React re-renders the rows
// that moved and nothing else.

import type { TaskRecord, TreeModel } from "./model.ts";

export const INDEX_STYLES = ["none", "outline", "numerical", "roman", "alphabetical"] as const;

export type IndexStyle = (typeof INDEX_STYLES)[number];

export function validStyle(style: string): style is IndexStyle {
  return (INDEX_STYLES as readonly string[]).includes(style);
}

/**
 * The dotted label for a node, given its zero-based sibling positions from the
 * top level down. `""` for the `none` style, an unknown style, or no positions.
 */
export function label(positions: readonly number[], style: string): string {
  if (style === "none" || !validStyle(style)) return "";
  if (positions.length === 0) return "";
  return positions.map((position, level) => segment(style, level, position)).join(".");
}

function segment(style: IndexStyle, level: number, position: number): string {
  switch (style) {
    case "numerical":
      return String(position + 1);
    case "roman":
      return romanUpper(position);
    case "alphabetical":
      return alphaUpper(position);
    case "outline":
      return outlineSegment(level, position);
    default:
      return "";
  }
}

// Outline cycles roman → alpha → numeric → alpha-lower → roman-lower every
// five levels, repeating (AbstractSpoon's outline numbering).
function outlineSegment(level: number, position: number): string {
  switch (level % 5) {
    case 0:
      return romanUpper(position);
    case 1:
      return alphaUpper(position);
    case 2:
      return String(position + 1);
    case 3:
      return alphaLower(position);
    default:
      return romanLower(position);
  }
}

const alphaUpper = (position: number): string => alpha(position, 65);
const alphaLower = (position: number): string => alpha(position, 97);

// Spreadsheet-style letters: A..Z, then AA, AB, … so it never runs out.
function alpha(position: number, base: number): string {
  let n = position + 1;
  let out = "";
  while (n > 0) {
    out = String.fromCharCode(base + ((n - 1) % 26)) + out;
    n = Math.floor((n - 1) / 26);
  }
  return out;
}

const ROMAN: readonly (readonly [number, string])[] = [
  [1000, "M"],
  [900, "CM"],
  [500, "D"],
  [400, "CD"],
  [100, "C"],
  [90, "XC"],
  [50, "L"],
  [40, "XL"],
  [10, "X"],
  [9, "IX"],
  [5, "V"],
  [4, "IV"],
  [1, "I"],
];

function romanUpper(position: number): string {
  let n = position + 1;
  let out = "";
  for (const [value, symbol] of ROMAN) {
    while (n >= value) {
      out += symbol;
      n -= value;
    }
  }
  return out;
}

const romanLower = (position: number): string => romanUpper(position).toLowerCase();

/**
 * Recomputes `index` and `depth` for `parentId`'s children and their subtrees —
 * the run a structural change made stale. Records outside that run keep their
 * object identity, and so does the model when nothing actually moved.
 */
export function relabel(model: TreeModel, parentId: number): TreeModel {
  const positions = parentPositions(model, parentId);
  if (positions === null) return model;

  const next: Record<number, TaskRecord> = {};
  let changed = false;

  const walk = (ownerId: number, ownerPositions: readonly number[], depth: number): void => {
    const order = model.childIds[ownerId] ?? [];
    order.forEach((childId, index) => {
      const record = model.tasks[childId];
      if (record === undefined) return;
      const chain = [...ownerPositions, index];
      const index_ = label(chain, model.indexStyle);
      if (record.index !== index_ || record.depth !== depth) {
        next[childId] = { ...record, index: index_, depth };
        changed = true;
      }
      walk(childId, chain, depth + 1);
    });
  };

  walk(parentId, positions, positions.length);

  if (!changed) return model;
  return { ...model, tasks: { ...model.tasks, ...next } };
}

// The position chain of `parentId` itself, top level down. `[]` for the system
// root; `null` when the id is not in the tree at all.
function parentPositions(model: TreeModel, parentId: number): number[] | null {
  if (parentId === model.rootId) return [];
  const chain: number[] = [];
  const seen = new Set<number>();
  let current: number | undefined = parentId;
  while (current !== undefined && current !== model.rootId) {
    if (seen.has(current)) return null;
    seen.add(current);
    const record: TaskRecord | undefined = model.tasks[current];
    if (record === undefined) return null;
    const siblings = model.childIds[record.parent_id] ?? [];
    const index = siblings.indexOf(current);
    if (index < 0) return null;
    chain.unshift(index);
    current = record.parent_id;
  }
  return chain;
}
