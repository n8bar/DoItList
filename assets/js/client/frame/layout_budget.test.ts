import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { describe, it } from "node:test";

import {
  ASYNC_REGIONS,
  COUNT_MIN_WIDTH,
  LIST_ROW_HEIGHT,
  reservation,
  reservedHeight,
} from "./layout_budget.ts";

const CLIENT_DIR = join(import.meta.dirname, "..");

/** Every `.ts`/`.tsx` in the client except the tests. */
function sourceFiles(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return sourceFiles(path);
    if (!/\.tsx?$/.test(entry.name) || entry.name.includes(".test.")) return [];
    return [path];
  });
}

/** Region ids the client actually names, wherever it names them. */
function regionsUsedInSource(): { region: string; file: string }[] {
  const pattern = /(?:region=|reservedHeight\(|reservation\()"([a-z-]+)"/g;
  const found: { region: string; file: string }[] = [];

  for (const file of sourceFiles(CLIENT_DIR)) {
    if (file.endsWith(join("frame", "layout_budget.ts"))) continue; // the table itself
    const text = readFileSync(file, "utf8");
    for (const match of text.matchAll(pattern)) {
      found.push({ region: match[1] as string, file });
    }
  }
  return found;
}

describe("the layout budget", () => {
  it("has at least one region, and no duplicates", () => {
    assert.ok(ASYNC_REGIONS.length > 0);
    assert.equal(new Set(ASYNC_REGIONS).size, ASYNC_REGIONS.length);
  });

  // The line this file exists to hold: a region that paints before its data
  // exists must say how much room it holds open, or it will shift the page.
  // Checked against what the SOURCE actually asks for, not against the table's
  // own keys — a screen naming a region nobody budgeted for is the failure mode.
  it("budgets every region the client actually asks for", () => {
    const used = regionsUsedInSource();
    assert.ok(used.length > 0, "found no region ids in the client at all");

    for (const { region, file } of used) {
      assert.ok(
        (ASYNC_REGIONS as readonly string[]).includes(region),
        `${file} reserves space for "${region}", which the budget does not declare`,
      );
    }
  });

  it("gives every region a usable reservation", () => {
    for (const region of ASYNC_REGIONS) {
      const budget = reservation(region);
      assert.ok(budget.rows >= 1, `${region} reserves no rows`);
      assert.ok(budget.rowHeight > 0, `${region} reserves no height`);
      assert.notEqual(budget.label, "", `${region} tells assistive tech nothing`);
    }
  });

  // Important 2: the reservation and the real row must be ONE number. If the
  // list's reservation ever stops being the shared token, six skeleton rows
  // stop being six real rows' worth of space.
  it("reserves the Initiatives list at the shared row height", () => {
    assert.equal(reservation("initiatives-list").rowHeight, LIST_ROW_HEIGHT);
  });

  it("renders the real Initiatives row at the same shared row height", () => {
    const screen = readFileSync(join(CLIENT_DIR, "screens/initiatives.tsx"), "utf8");
    assert.match(
      screen,
      /minHeight: `\$\{LIST_ROW_HEIGHT\}px`/,
      "the Initiatives row no longer sizes itself from LIST_ROW_HEIGHT",
    );
  });

  // Concrete numbers, not the formula restated: six 48px rows plus five 8px
  // gaps between them is 328px, full stop.
  it("reserves the Initiatives list's six rows plus the gaps between them", () => {
    assert.equal(reservation("initiatives-list").rows, 6);
    assert.equal(reservedHeight("initiatives-list"), "328px");
  });

  it("gives the single-row Initiative header no gap to pay for", () => {
    assert.equal(reservation("initiative-header").rows, 1, "this only tests a single row if the fixture stays one");
    assert.equal(reservedHeight("initiative-header"), "80px");
  });

  it("holds a width open for numbers that have not arrived", () => {
    assert.match(COUNT_MIN_WIDTH, /^\d+(\.\d+)?(ch|rem|px)$/);
  });
});
