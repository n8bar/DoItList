// What the client does when the server says something changed (m04.01 item 1.5).
//
// Deliberately blunt: the channel carries no tree, so a `changed` is a signal
// to re-read the Initiative through the ordinary `/app/api` path — the same
// read the screen made on mount, through the same client. Arc 3 replaces this
// with a delta envelope; until it does, refetching is the honest version and it
// is one round trip on a change the user can see.
//
// The Initiatives list has no topic of its own, so a change on an Initiative
// the tab is watching also refreshes that Initiative's row in the list (m04.02
// item 4.6) — one summary read, patched in place, never the whole index — and
// only when the list has actually been read, so a deep link never fetches a
// screen nobody asked for. A burst of changes on one Initiative is coalesced
// into one read (`coalesce`). Returning to the index re-reads the list in the
// background (`revalidateList`) and patches the rows that differ.
//
// Refetching and revocation are ONE unit (`createInitiativeSync`), because they
// race: a read already in flight when access is taken away would otherwise
// resolve afterwards and quietly write the tree back. They share a sequence, so
// revoking is also an invalidation.

import type { ApiClient } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree } from "../api/types.ts";
import { mergeSummaries, patchSummary } from "../screens/initiatives_model.ts";
import type { DomainStore } from "../state/domain.ts";
import { forgetInitiative, putTree } from "../state/domain.ts";
import { fromSnapshot } from "../tree/model.ts";
import { UNUSABLE_TREE_NOTICE } from "../tree/validate.ts";
import type { UiStore } from "../state/ui.ts";
import { pushNotice } from "../state/ui.ts";
import type { TreeCache } from "../storage/snapshots.ts";
import type { ChangedEvent, Timers } from "./connection.ts";

/** How long a burst of changes on one Initiative is held before one summary read. */
export const SUMMARY_DEBOUNCE_MS = 300;

export interface Coalescer<K> {
  /** Ask for `key`'s work; a repeat inside the window restarts it, the work runs once. */
  request(key: K): void;
  /** Drop `key`'s pending work, if any. */
  cancel(key: K): void;
  /** Keys with work still pending. */
  pending(): readonly K[];
}

/**
 * One trailing-edge debounce per key: `run` fires once per key, `ms` after
 * the last request for it. Keys never wait on each other. Pure over the
 * injected timers, so tests drive it with a fake clock.
 */
export function coalesce<K>(timers: Timers, ms: number, run: (key: K) => void): Coalescer<K> {
  const handles = new Map<K, unknown>();
  return {
    request(key) {
      const held = handles.get(key);
      if (held !== undefined) timers.clearTimeout(held);
      handles.set(
        key,
        timers.setTimeout(() => {
          handles.delete(key);
          run(key);
        }, ms),
      );
    },
    cancel(key) {
      const held = handles.get(key);
      if (held === undefined) return;
      timers.clearTimeout(held);
      handles.delete(key);
    },
    pending: () => [...handles.keys()],
  };
}

/**
 * Who is allowed to write what a read came back with.
 *
 * Every read claims a sequence before it starts and must still hold the newest
 * one to land. Anything that makes older reads wrong — a newer read, or access
 * being taken away — bumps the sequence, and the loser is dropped on arrival
 * rather than written over the truth. A read begun *after* a revocation (the
 * user was let back in) claims a fresh sequence and lands normally, so nothing
 * needs to be un-revoked.
 */
export interface SyncGuard {
  /** Claim a sequence for a read of `id`'s tree. */
  beginTree(id: number): number;
  /** Claim a sequence for a read of the Initiatives index. */
  beginList(): number;
  /** Claim a sequence for a read of `id`'s index row. */
  beginSummary(id: number): number;
  /** May a tree read holding `seq` still write? */
  currentTree(id: number, seq: number): boolean;
  /** May a list read holding `seq` still write? */
  currentList(seq: number): boolean;
  /** May a row read holding `seq` still write? A newer list read outranks it too. */
  currentSummary(id: number, seq: number): boolean;
  /** Access to `id` is gone: every read in flight for it, and for the index. */
  revoke(id: number): void;
}

export function createSyncGuard(): SyncGuard {
  const trees = new Map<number, number>();
  const summaries = new Map<number, number>();
  let list = 0;

  const bump = (map: Map<number, number>, id: number): number => {
    const seq = (map.get(id) ?? 0) + 1;
    map.set(id, seq);
    return seq;
  };

  return {
    beginTree: (id) => bump(trees, id),
    // A whole-list read supersedes every row read still out: its answer
    // carries every row, newer than any of them.
    beginList: () => {
      summaries.clear();
      return (list += 1);
    },
    beginSummary: (id) => bump(summaries, id),
    currentTree: (id, seq) => trees.get(id) === seq,
    currentList: (seq) => list === seq,
    currentSummary: (id, seq) => summaries.get(id) === seq,
    revoke(id) {
      // The index carries a row for `id` too, so a list read from before the
      // revocation would put it straight back — and so would a row read.
      bump(trees, id);
      bump(summaries, id);
      list += 1;
    },
  };
}

export interface SyncDeps {
  api: ApiClient;
  domain: DomainStore;
  ui: UiStore;
  /** Hands the app the "you don't have access" screen. */
  onForbidden(): void;
  /**
   * The local recovery cache. A tree is written to it on the SAME path that
   * writes it to the store — a snapshot that bypassed the guard could cache a
   * tree the user is no longer allowed to see — and losing access deletes what
   * is already there, on the same path that forgets the in-memory copy.
   */
  snapshots?: Pick<TreeCache, "cacheTree" | "forgetTree">;
  /** Injected in tests; one is made per client otherwise. */
  guard?: SyncGuard;
  /** Injected in tests so the summary debounce is assertable. */
  timers?: Timers;
}

export interface InitiativeSync {
  /** For `Connection.onChanged`. Never throws, never rejects. */
  onChanged(event: ChangedEvent): void;
  /** For `Connection.onAccessRevoked`. */
  onAccessRevoked(initiativeId: number): void;
  /**
   * Re-reads the Initiatives index behind a list already on the glass and
   * patches the rows that differ (item 4.6). Nothing is cleared first, so the
   * page never goes back to a skeleton; a failed read changes nothing. Never
   * throws, never rejects.
   */
  revalidateList(): void;
}

/**
 * The client's two answers to the live channel, built together so they cannot
 * be wired up with separate state (m04.01 1.5).
 *
 *   * a change — re-read what we are holding, newest answer wins;
 *   * access taken away — forget the copy we hold, including the row in the
 *     index, invalidate anything still in flight for it, and, if that
 *     Initiative is the screen the user is on, say so rather than leaving a
 *     tree on the glass that the server would now refuse.
 */
export function createInitiativeSync(deps: SyncDeps): InitiativeSync {
  const { api, domain, ui, onForbidden } = deps;
  const guard = deps.guard ?? createSyncGuard();
  const timers: Timers = deps.timers ?? {
    setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
    clearTimeout: (handle) => globalThis.clearTimeout(handle as number),
  };

  /**
   * Re-reads one tree. A read that cannot be a tree is read once more — the
   * same rule the screen follows — and a second failure is said out loud rather
   * than dropped, because the copy on screen is now known to be stale and
   * nothing else will tell the user (item 1.6.2).
   */
  const refreshTree = async (initiativeId: number, retry: boolean): Promise<void> => {
    const seq = guard.beginTree(initiativeId);
    const tree = await api.get<InitiativeTree>(`/initiatives/${initiativeId}`);
    if (!tree.ok || !guard.currentTree(initiativeId, seq)) return;

    try {
      const model = fromSnapshot(tree.data);
      putTree(domain, model);
      deps.snapshots?.cacheTree(model);
    } catch {
      if (retry) {
        await refreshTree(initiativeId, false);
        return;
      }
      pushNotice(ui, {
        kind: "error",
        title: "This Initiative could not be refreshed",
        message: UNUSABLE_TREE_NOTICE,
      });
    }
  };

  /**
   * Re-reads one index row and patches it in place. A row the list no longer
   * holds (revoked meanwhile, or never there) is left out — `patchSummary`
   * never adds. A refused read is nothing to tell the user about: the row
   * on screen is a moment old, not wrong.
   */
  const refreshSummary = async (initiativeId: number): Promise<void> => {
    if (domain.get().initiativeSummaries === null) return;
    const seq = guard.beginSummary(initiativeId);
    const row = await api.get<InitiativeSummary>(`/initiatives/${initiativeId}/summary`);
    if (!row.ok || !guard.currentSummary(initiativeId, seq)) return;
    domain.set((state) => {
      const current = state.initiativeSummaries;
      if (current === null) return state;
      const next = patchSummary(current, row.data);
      return next === current ? state : { ...state, initiativeSummaries: next };
    });
  };

  // A burst of task changes on one Initiative is one row read.
  const rowReads = coalesce<number>(timers, SUMMARY_DEBOUNCE_MS, (initiativeId) => {
    void refreshSummary(initiativeId);
  });

  return {
    onChanged(event: ChangedEvent) {
      const { initiativeId } = event;

      // Only a list already on the glass has a row to patch.
      if (domain.get().initiativeSummaries !== null) rowReads.request(initiativeId);

      if (domain.get().trees[initiativeId] !== undefined) {
        void refreshTree(initiativeId, true);
      }
    },

    revalidateList() {
      void (async () => {
        if (domain.get().initiativeSummaries === null) return;
        const seq = guard.beginList();
        const list = await api.get<InitiativeSummary[]>("/initiatives");
        if (!list.ok || !guard.currentList(seq)) return;
        domain.set((state) => {
          const current = state.initiativeSummaries;
          if (current === null) return state;
          const next = mergeSummaries(current, list.data);
          return next === current ? state : { ...state, initiativeSummaries: next };
        });
      })();
    },

    onAccessRevoked(initiativeId: number) {
      rowReads.cancel(initiativeId);
      guard.revoke(initiativeId);
      forgetInitiative(domain, initiativeId);
      // The copy on disk is part of "forget it", not an afterthought: cached
      // data is purged on access loss, not only on logout (spec §12). The cache
      // sequences this against any write still in flight for the same id.
      void deps.snapshots?.forgetTree(initiativeId);
      const route = ui.get().route;
      if (route.kind === "initiative" && route.id === initiativeId) onForbidden();
    },
  };
}
