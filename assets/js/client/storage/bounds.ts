// What the recovery cache is allowed to keep (m04.01 item 3.5).
//
// The cache is a recovery aid, not an offline database (spec §5), so it is
// bounded three ways — age, count and total bytes — and the decision about what
// to drop is a pure function of the records and the clock. `db.ts` only carries
// it out. Unacknowledged operations are never evictable: dropping a write the
// user made would lose their work to make room for a copy of the server's.

export interface BoundLimits {
  /** Snapshots older than this are stale enough to be worthless. */
  readonly maxAgeMs: number;
  /** Total snapshot payload bytes kept for one account. */
  readonly maxTotalBytes: number;
  /** How many Initiatives' snapshots are kept at once. */
  readonly maxSnapshots: number;
}

export const MAX_SNAPSHOT_AGE_MS = 7 * 24 * 60 * 60 * 1000;
export const MAX_TOTAL_BYTES = 25 * 1024 * 1024;
export const MAX_SNAPSHOTS = 20;

export const DEFAULT_LIMITS: BoundLimits = {
  maxAgeMs: MAX_SNAPSHOT_AGE_MS,
  maxTotalBytes: MAX_TOTAL_BYTES,
  maxSnapshots: MAX_SNAPSHOTS,
};

/** Just enough of a snapshot to decide its fate. */
export interface BoundedRecord {
  readonly initiativeId: number;
  readonly savedAt: number;
  readonly bytes: number;
}

/** Oldest first; ties broken by id so the plan is deterministic. */
const byAge = (a: BoundedRecord, b: BoundedRecord): number =>
  a.savedAt === b.savedAt ? a.initiativeId - b.initiativeId : a.savedAt - b.savedAt;

/**
 * The Initiative ids to evict, oldest first.
 *
 * Age first (a stale snapshot is dropped even when there is room), then count,
 * then bytes. `keep` is never evicted — the Initiative the user is looking at
 * stays, or reopening the tab would throw away the very snapshot that was about
 * to be useful.
 */
export function evictionPlan(
  records: readonly BoundedRecord[],
  now: number,
  limits: BoundLimits = DEFAULT_LIMITS,
  keep: number | null = null,
): number[] {
  const evicted = new Set<number>();
  const sorted = [...records].sort(byAge);

  for (const record of sorted) {
    if (now - record.savedAt > limits.maxAgeMs) evicted.add(record.initiativeId);
  }

  const survivors = () => sorted.filter((record) => !evicted.has(record.initiativeId));
  const evictOldest = (): boolean => {
    for (const record of survivors()) {
      if (record.initiativeId === keep) continue;
      evicted.add(record.initiativeId);
      return true;
    }
    return false;
  };

  while (survivors().length > limits.maxSnapshots) {
    if (!evictOldest()) break;
  }

  const total = () => survivors().reduce((sum, record) => sum + record.bytes, 0);
  while (total() > limits.maxTotalBytes) {
    if (!evictOldest()) break;
  }

  return sorted.filter((r) => evicted.has(r.initiativeId)).map((r) => r.initiativeId);
}

/**
 * What to throw away to survive a `QuotaExceededError`: a quarter of what is
 * held, at least one record, oldest first. Blunt on purpose — the browser has
 * already said "no", and a precise answer needs a number it will not give us.
 */
export function quotaEvictionPlan(
  records: readonly BoundedRecord[],
  keep: number | null = null,
): number[] {
  const candidates = [...records].sort(byAge).filter((r) => r.initiativeId !== keep);
  if (candidates.length === 0) return [];
  const count = Math.max(1, Math.ceil(candidates.length / 4));
  return candidates.slice(0, count).map((r) => r.initiativeId);
}
