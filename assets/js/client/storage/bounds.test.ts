import assert from "node:assert/strict";
import { describe, it } from "node:test";

import type { BoundLimits, BoundedRecord } from "./bounds.ts";
import {
  DEFAULT_LIMITS,
  MAX_SNAPSHOTS,
  MAX_SNAPSHOT_AGE_MS,
  MAX_TOTAL_BYTES,
  evictionPlan,
  quotaEvictionPlan,
} from "./bounds.ts";

const NOW = 1_700_000_000_000;

const record = (initiativeId: number, ageMs: number, bytes = 10): BoundedRecord => ({
  initiativeId,
  savedAt: NOW - ageMs,
  bytes,
});

const limits = (overrides: Partial<BoundLimits> = {}): BoundLimits => ({
  ...DEFAULT_LIMITS,
  ...overrides,
});

describe("the recovery cache's bounds (item 3.5)", () => {
  it("keeps everything that is small, few and fresh", () => {
    const held = [record(1, 0), record(2, 1000)];
    assert.deepEqual(evictionPlan(held, NOW), []);
  });

  it("drops snapshots older than the age limit even when there is room", () => {
    const held = [record(1, MAX_SNAPSHOT_AGE_MS + 1), record(2, 60_000)];
    assert.deepEqual(evictionPlan(held, NOW), [1]);
  });

  it("drops the oldest first once there are too many", () => {
    const held = Array.from({ length: MAX_SNAPSHOTS + 3 }, (_, i) => record(i + 1, (30 - i) * 1000));
    // Ages descend with the index, so 1 is the oldest.
    assert.deepEqual(evictionPlan(held, NOW), [1, 2, 3]);
  });

  it("drops the oldest first once the total is too big", () => {
    const big = Math.ceil(MAX_TOTAL_BYTES / 2);
    const held = [record(1, 3000, big), record(2, 2000, big), record(3, 1000, big)];
    assert.deepEqual(evictionPlan(held, NOW), [1]);
  });

  it("never evicts the Initiative the user is looking at", () => {
    const big = MAX_TOTAL_BYTES;
    const held = [record(1, 3000, big), record(7, 2000, big)];
    assert.deepEqual(evictionPlan(held, NOW, DEFAULT_LIMITS, 1), [7]);
  });

  it("still drops the kept Initiative when it is simply too old to trust", () => {
    const held = [record(7, MAX_SNAPSHOT_AGE_MS * 2)];
    assert.deepEqual(evictionPlan(held, NOW, DEFAULT_LIMITS, 7), [7]);
  });

  it("stops rather than emptying itself when the only survivor is the kept one", () => {
    const held = [record(7, 0, MAX_TOTAL_BYTES * 3)];
    assert.deepEqual(evictionPlan(held, NOW, DEFAULT_LIMITS, 7), []);
  });

  it("is deterministic when two snapshots share a timestamp", () => {
    const held = [record(9, 5000), record(3, 5000), record(1, 0)];
    assert.deepEqual(evictionPlan(held, NOW, limits({ maxSnapshots: 1 })), [3, 9]);
  });

  it("gives back a quarter of what is held, oldest first, under quota pressure", () => {
    const held = Array.from({ length: 8 }, (_, i) => record(i + 1, (10 - i) * 1000));
    assert.deepEqual(quotaEvictionPlan(held), [1, 2]);
  });

  it("gives back at least one record under quota pressure", () => {
    assert.deepEqual(quotaEvictionPlan([record(4, 1000), record(5, 500)]), [4]);
  });

  it("has nothing to give back when only the kept Initiative is held", () => {
    assert.deepEqual(quotaEvictionPlan([record(7, 1000)], 7), []);
  });
});
