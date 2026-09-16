import assert from "node:assert/strict";
import { describe, it } from "node:test";

import {
  ASYNC_REGIONS,
  COUNT_MIN_WIDTH,
  ROW_GAP,
  reservation,
  reservedHeight,
} from "./layout_budget.ts";

describe("the layout budget", () => {
  it("has at least one region, and no duplicates", () => {
    assert.ok(ASYNC_REGIONS.length > 0);
    assert.equal(new Set(ASYNC_REGIONS).size, ASYNC_REGIONS.length);
  });

  // The line this file exists to hold: a region that paints before its data
  // exists must say how much room it holds open, or it will shift the page.
  it("makes every async region declare a usable reservation", () => {
    for (const region of ASYNC_REGIONS) {
      const budget = reservation(region);
      assert.ok(budget !== undefined, `${region} declares no reservation`);
      assert.ok(budget.rows >= 1, `${region} reserves no rows`);
      assert.ok(budget.rowHeight > 0, `${region} reserves no height`);
      assert.notEqual(budget.label, "", `${region} tells assistive tech nothing`);
    }
  });

  it("reserves the rows plus the gaps between them", () => {
    for (const region of ASYNC_REGIONS) {
      const { rows, rowHeight } = reservation(region);
      assert.equal(reservedHeight(region), `${rows * rowHeight + (rows - 1) * ROW_GAP}px`);
    }
  });

  it("gives a single row no gap to pay for", () => {
    const single = ASYNC_REGIONS.find((region) => reservation(region).rows === 1);
    if (single === undefined) return;
    assert.equal(reservedHeight(single), `${reservation(single).rowHeight}px`);
  });

  it("holds a width open for numbers that have not arrived", () => {
    assert.match(COUNT_MIN_WIDTH, /^\d+(\.\d+)?(ch|rem|px)$/);
  });
});
