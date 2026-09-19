// What the client does with what the live channel says (m04.01 1.5, m04.03 1.4).
//
// One sync session per Initiative (`session.ts` holds the rules; this file
// holds the state and does the reading). Everything that changes a tree goes
// through here — the snapshot the screen reads on mount, the delta envelopes
// off the channel, the screen's own writes as they are queued and answered —
// so there is one place canonical truth, the sequence and the predictions
// meet, and what the domain store holds is always `shown(session)`: truth
// with the unanswered predictions folded on top. A delta landing under a
// pending write never erases the write's guess.
//
// The gap rule is the one impure part: an envelope that skips ahead starts a
// short hold (a later one may fill the gap), and a hold that expires with the
// gap still open re-reads the tree. Reads are guarded (`SyncGuard`): the
// newest wins, and a read still out when access is taken away is dropped on
// arrival rather than written over the forget.
//
// The channel is joined BEFORE any read goes out (m04.03 3.1) — `read` takes
// the subscription itself, so the order is not an accident of effect order —
// and every join reply's `seq` comes here (3.3): one past canonical means the
// socket was down while something changed, and the tree is re-read at once
// rather than after the gap hold. `onSynced` tells the screen when the
// session is level with the server again — after a server snapshot installs,
// or after a join that says nothing was missed — which is when pending intent
// is rebased and replayed (3.2).
//
// The Initiatives list has no topic of its own, so a delta on an Initiative
// the tab is watching also refreshes that Initiative's row in the list (m04.02
// item 4.6) — one summary read, patched in place, never the whole index — and
// only when the list has actually been read. A burst is coalesced into one
// read. Returning to the index re-reads the list in the background
// (`revalidateList`) and patches the rows that differ.

import type { ApiClient, Result } from "../api/client.ts";
import type { InitiativeSummary, InitiativeTree, Member } from "../api/types.ts";
import { mergeSummaries, patchSummary } from "../screens/initiatives_model.ts";
import type { DomainStore } from "../state/domain.ts";
import { forgetInitiative, putMembers, putTree } from "../state/domain.ts";
import type { TreeDelta } from "../tree/delta.ts";
import type { InitiativeHeader, TreeModel } from "../tree/model.ts";
import type { Flight } from "../tree/optimistic.ts";
import { UNUSABLE_TREE_NOTICE } from "../tree/validate.ts";
import type { UiStore } from "../state/ui.ts";
import { pushNotice } from "../state/ui.ts";
import type { TreeCache } from "../storage/snapshots.ts";
import type { Timers } from "./connection.ts";
import type { DeltaEnvelope } from "./envelope.ts";
import type { Outcome, SessionState, Settled } from "./session.ts";
import {
  GAP_HOLD_MS,
  acknowledge,
  begin,
  emptySession,
  gapOpen,
  heard,
  install,
  installCached,
  patchHeader,
  receive,
  reject,
  seqOf,
  shown,
} from "./session.ts";

/** How long a burst of changes on one Initiative is held before one summary read. */
export const SUMMARY_DEBOUNCE_MS = 300;

/** How long canonical is given to settle before the device's copy is rewritten (m04.03 2.2). */
export const SNAPSHOT_DEBOUNCE_MS = 1000;

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
  /** Claim a sequence for a read of `id`'s members. */
  beginMembers(id: number): number;
  /** Claim a sequence for a read of the Initiatives index. */
  beginList(): number;
  /** Claim a sequence for a read of `id`'s index row. */
  beginSummary(id: number): number;
  /** May a tree read holding `seq` still write? */
  currentTree(id: number, seq: number): boolean;
  /** May a members read holding `seq` still write? */
  currentMembers(id: number, seq: number): boolean;
  /** May a list read holding `seq` still write? */
  currentList(seq: number): boolean;
  /** May a row read holding `seq` still write? A newer list read outranks it too. */
  currentSummary(id: number, seq: number): boolean;
  /** Access to `id` is gone: every read in flight for it, and for the index. */
  revoke(id: number): void;
}

export function createSyncGuard(): SyncGuard {
  const trees = new Map<number, number>();
  const members = new Map<number, number>();
  const summaries = new Map<number, number>();
  let list = 0;

  const bump = (map: Map<number, number>, id: number): number => {
    const seq = (map.get(id) ?? 0) + 1;
    map.set(id, seq);
    return seq;
  };

  return {
    beginTree: (id) => bump(trees, id),
    beginMembers: (id) => bump(members, id),
    // A whole-list read supersedes every row read still out: its answer
    // carries every row, newer than any of them.
    beginList: () => {
      summaries.clear();
      return (list += 1);
    },
    beginSummary: (id) => bump(summaries, id),
    currentTree: (id, seq) => trees.get(id) === seq,
    currentMembers: (id, seq) => members.get(id) === seq,
    currentList: (seq) => list === seq,
    currentSummary: (id, seq) => summaries.get(id) === seq,
    revoke(id) {
      // The index carries a row for `id` too, so a list read from before the
      // revocation would put it straight back — and so would a row read.
      bump(trees, id);
      bump(members, id);
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
   * The local recovery cache. Canonical is written to it — never what is
   * shown — a moment after it last changed, on the SAME path that writes it
   * to the store: a snapshot that bypassed the guard could cache a tree the
   * user is no longer allowed to see. Losing access deletes what is already
   * there, on the same path that forgets the in-memory copy.
   */
  snapshots?: Pick<TreeCache, "cacheTree" | "forgetTree">;
  /** Injected in tests; one is made per client otherwise. */
  guard?: SyncGuard;
  /** Injected in tests so the debounce and the gap hold are assertable. */
  timers?: Timers;
  /** How long a gap is given to fill before the tree is re-read. */
  gapHoldMs?: number;
  /**
   * The live channel's subscribe/unsubscribe, refcounted by the connection.
   * `read` holds a subscription for the read's duration, so the join is
   * always ahead of the snapshot. Without one, reads are unsubscribed reads.
   */
  channel?: { subscribe(id: number): void; unsubscribe(id: number): void };
}

export interface InitiativeSync {
  /** For `Connection.onDelta`. Never throws, never rejects. */
  onDelta(envelope: DeltaEnvelope): void;
  /** For `Connection.onAccessRevoked`. */
  onAccessRevoked(initiativeId: number): void;
  /**
   * For `Connection.onJoined`: the join reply's `seq` for `initiativeId`,
   * fired on the first join and on each rejoin after a drop (m04.03 3.3). A
   * session behind it re-reads now — no hold, the server has said we missed
   * something; one level with it is told so (`onSynced`); one with no server
   * snapshot yet does nothing, the mount read is on its way.
   */
  onJoined(initiativeId: number, seq: number): void;
  /**
   * The screen is on `id`: its channel is held for as long as the returned
   * release is not called. Refcounted by the connection, so a read's own hold
   * and the screen's stack.
   */
  watch(id: number): () => void;
  /**
   * The screen's own read of `id`'s tree (mount, Try again). The channel is
   * subscribed BEFORE the request goes out (m04.03 3.1), so anything that
   * changes meanwhile is held and follows the snapshot; the hold is released
   * when the read is back (the screen's own `watch` keeps the channel). The
   * answer is the screen's to install (`install`) — it owns the read's status.
   */
  read(id: number): Promise<Result<InitiativeTree>>;
  /**
   * Re-reads the Initiatives index behind a list already on the glass and
   * patches the rows that differ (item 4.6). Nothing is cleared first, so the
   * page never goes back to a skeleton; a failed read changes nothing. Never
   * throws, never rejects.
   */
  revalidateList(): void;
  /**
   * A snapshot the screen read (on mount, or Try again). Installed forward
   * only, and every envelope held while it was in flight follows it. Throws
   * when the read cannot be a tree — the screen reads once more, then says so.
   */
  install(tree: InitiativeTree): void;
  /**
   * The tree this device last saved, painted before the server answers
   * (m04.03 2.2). Taken only into an empty session — anything the server has
   * said since is newer — and never written back to the cache it came from.
   * Returns whether it was taken.
   */
  installCached(model: TreeModel): boolean;
  /** Server truth for `id` — no predictions — or `undefined` before a snapshot. */
  canonical(id: number): TreeModel | undefined;
  /** The keys of the writes still in flight for `id`, in submission order. */
  flights(id: number): readonly string[];
  /** A write queued: its prediction is shown at once. Returns what is now shown. */
  begin(id: number, flight: Flight): TreeModel | undefined;
  /**
   * A write's reply. `seq` is the reply's own sequence, when the server sent
   * one. `createdId` is the row the write added and `tempId` the stand-in it
   * was drawn under — both `null` when there was none, or when the write's
   * broadcast settled it first (`onSettled` said so then).
   */
  succeed(
    id: number,
    key: string,
    delta: TreeDelta,
    seq?: number,
  ): { createdId: number | null; tempId: number | null };
  /** A write refused: the prediction goes. */
  reject(id: number, key: string): void;
  /** A header edit, predicted or answered, onto canonical. */
  patchHeader(id: number, patch: (header: InitiativeHeader) => InitiativeHeader): void;
  /**
   * Told when a write's own broadcast settles it before its reply does — the
   * screen clears the write's marks then, not when the reply comes.
   */
  onSettled(id: number, listener: (settled: Settled) => void): () => void;
  /**
   * Told when `id`'s session is level with the server: a server snapshot
   * installed (mount, a gap's re-read, a resync after a drop), or a join said
   * nothing was missed. The screen rebases and replays pending intent then
   * (m04.03 3.2) — never over the device's copy alone.
   */
  onSynced(id: number, listener: () => void): () => void;
}

/**
 * The client's answers to the live channel and to its own writes, built
 * together so they cannot be wired up with separate state (m04.01 1.5, m04.03 1.4).
 */
export function createInitiativeSync(deps: SyncDeps): InitiativeSync {
  const { api, domain, ui, onForbidden } = deps;
  const guard = deps.guard ?? createSyncGuard();
  const gapHoldMs = deps.gapHoldMs ?? GAP_HOLD_MS;
  const timers: Timers = deps.timers ?? {
    setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
    clearTimeout: (handle) => globalThis.clearTimeout(handle as number),
  };

  const sessions = new Map<number, SessionState>();
  const holds = new Map<number, unknown>();
  const listeners = new Map<number, Set<(settled: Settled) => void>>();
  const syncedListeners = new Map<number, Set<() => void>>();
  /** Initiatives with a re-read out: one at a time, a burst past the buffer asks once. */
  const reading = new Set<number>();
  /** Screen reads out per Initiative: a re-read is not started under one. */
  const screenReads = new Map<number, number>();

  const sessionOf = (id: number): SessionState => sessions.get(id) ?? emptySession;

  /**
   * Files a session and everything that follows from it: what is shown, the
   * hold on an open gap, the marks a broadcast settled, and the reads an
   * applied envelope asks for.
   */
  const commit = (id: number, outcome: Outcome, persist = true): void => {
    const { state } = outcome;
    const before = sessions.get(id)?.canonical ?? null;
    sessions.set(id, state);
    const model = shown(state);
    if (model !== null) putTree(domain, model);
    // Truth changed: the device's copy follows, once things settle down.
    if (persist && state.canonical !== null && state.canonical !== before) snapshotWrites.request(id);

    if (gapOpen(state)) hold(id);
    else release(id);

    for (const settled of outcome.settled) {
      for (const listener of listeners.get(id) ?? []) listener(settled);
    }

    if (outcome.applied.length > 0) {
      if (domain.get().initiativeSummaries !== null) rowReads.request(id);
      if (outcome.applied.some((envelope) => envelope.membersChanged)) void refreshMembers(id);
    }

    if (outcome.overflow) void resnapshot(id, true);
  };

  const only = (state: SessionState): Outcome => ({
    state,
    applied: [],
    settled: [],
    overflow: false,
  });

  /** Starts the gap hold for `id` unless one is already running. */
  const hold = (id: number): void => {
    if (holds.has(id)) return;
    holds.set(
      id,
      timers.setTimeout(() => {
        holds.delete(id);
        // The gap may have filled while we waited; only an open one is read for.
        if (gapOpen(sessionOf(id))) void resnapshot(id, true);
      }, gapHoldMs),
    );
  };

  const release = (id: number): void => {
    const handle = holds.get(id);
    if (handle === undefined) return;
    timers.clearTimeout(handle);
    holds.delete(id);
  };

  /**
   * Re-reads one tree and installs it. A read that cannot be a tree is read
   * once more — the same rule the screen follows — and a second failure is
   * said out loud rather than dropped, because the copy on screen is now known
   * to be behind and nothing else will tell the user (item 1.6.2).
   */
  const resnapshot = async (id: number, retry: boolean): Promise<void> => {
    if (reading.has(id) || (screenReads.get(id) ?? 0) > 0) return;
    reading.add(id);
    try {
      await readTree(id, retry);
    } finally {
      reading.delete(id);
    }
  };

  const readTree = async (id: number, retry: boolean): Promise<void> => {
    const seq = guard.beginTree(id);
    const tree = await api.get<InitiativeTree>(`/initiatives/${id}`);
    if (!tree.ok || !guard.currentTree(id, seq)) return;

    try {
      installTree(tree.data);
    } catch {
      if (retry) {
        await readTree(id, false);
        return;
      }
      pushNotice(ui, {
        kind: "error",
        title: "This Initiative could not be refreshed",
        message: UNUSABLE_TREE_NOTICE,
      });
    }
  };

  const installTree = (tree: InitiativeTree): void => {
    const id = tree.id;
    const outcome = install(sessionOf(id), tree);
    if (!outcome.installed) return;
    commit(id, outcome);
    synced(id);
  };

  const synced = (id: number): void => {
    for (const listener of syncedListeners.get(id) ?? []) listener();
  };

  /**
   * The member list changed: re-read it, and with it this user's own role,
   * which the broadcast cannot carry (it goes to everyone) and the header
   * needs (it decides what the tree lets the user do).
   */
  const refreshMembers = async (id: number): Promise<void> => {
    const seq = guard.beginMembers(id);
    const result = await api.get<Member[]>(`/initiatives/${id}/members`);
    if (!result.ok || !guard.currentMembers(id, seq)) return;
    putMembers(domain, id, result.data);

    const me = domain.get().user?.id ?? null;
    const mine = me === null ? undefined : result.data.find((member) => member.user_id === me);
    const state = sessionOf(id);
    if (mine === undefined || state.canonical === null || state.canonical.header.role === mine.role) {
      return;
    }
    const role = mine.role;
    commit(id, only(patchHeader(state, (header) => ({ ...header, role }))));
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

  // A burst of changes on one Initiative is one row read.
  const rowReads = coalesce<number>(timers, SUMMARY_DEBOUNCE_MS, (initiativeId) => {
    void refreshSummary(initiativeId);
  });

  // And one write of the device's copy — of canonical as it stands when the
  // burst is over, never of a prediction (m04.03 2.2).
  const snapshotWrites = coalesce<number>(timers, SNAPSHOT_DEBOUNCE_MS, (initiativeId) => {
    const canonical = sessionOf(initiativeId).canonical;
    if (canonical !== null) deps.snapshots?.cacheTree(canonical);
  });

  return {
    onDelta(envelope) {
      const id = envelope.initiativeId;
      commit(id, receive(sessionOf(id), envelope));
    },

    onJoined(id, seq) {
      const state = sessionOf(id);
      if (state.canonical === null) return;
      if (seq <= seqOf(state)) {
        if (state.synced) synced(id);
        return;
      }
      // Behind. Noting the sequence opens the gap, so if this read cannot be
      // started (a screen read is out) or fails, the hold's own re-read
      // follows; the read itself goes now.
      commit(id, only(heard(state, seq)));
      void resnapshot(id, true);
    },

    watch(id) {
      deps.channel?.subscribe(id);
      return () => deps.channel?.unsubscribe(id);
    },

    async read(id) {
      // Joined first, for the read's duration: whatever changes while the
      // request is out is held and follows the snapshot in order.
      deps.channel?.subscribe(id);
      screenReads.set(id, (screenReads.get(id) ?? 0) + 1);
      // Claims the newest read: a re-read still out lands nowhere.
      guard.beginTree(id);
      try {
        return await api.get<InitiativeTree>(`/initiatives/${id}`);
      } finally {
        screenReads.set(id, (screenReads.get(id) ?? 1) - 1);
        deps.channel?.unsubscribe(id);
      }
    },

    install: installTree,

    installCached(model) {
      const id = model.initiativeId;
      const outcome = installCached(sessionOf(id), model);
      if (!outcome.installed) return false;
      // What came off the disk does not go back onto it.
      commit(id, outcome, false);
      return true;
    },

    canonical: (id) => sessionOf(id).canonical ?? undefined,

    flights: (id) => sessionOf(id).flights.map((flight) => flight.key),

    begin(id, flight) {
      const state = sessionOf(id);
      if (state.canonical === null) return undefined;
      const next = begin(state, flight);
      commit(id, only(next));
      return shown(next) ?? undefined;
    },

    succeed(id, key, delta, seq) {
      const answered = acknowledge(sessionOf(id), key, delta, seq);
      commit(id, only(answered.state));
      return { createdId: answered.createdId, tempId: answered.flight?.tempId ?? null };
    },

    reject(id, key) {
      commit(id, only(reject(sessionOf(id), key)));
    },

    patchHeader(id, patch) {
      commit(id, only(patchHeader(sessionOf(id), patch)));
    },

    onSettled(id, listener) {
      const set = listeners.get(id) ?? new Set();
      set.add(listener);
      listeners.set(id, set);
      return () => {
        set.delete(listener);
        if (set.size === 0) listeners.delete(id);
      };
    },

    onSynced(id, listener) {
      const set = syncedListeners.get(id) ?? new Set();
      set.add(listener);
      syncedListeners.set(id, set);
      return () => {
        set.delete(listener);
        if (set.size === 0) syncedListeners.delete(id);
      };
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
      // The session goes whole: its truth, its held envelopes, its hold.
      release(initiativeId);
      sessions.delete(initiativeId);
      // A read still out is the guard's to drop; a new one may start at once.
      reading.delete(initiativeId);
      rowReads.cancel(initiativeId);
      // A copy waiting to be written would put back what is about to be deleted.
      snapshotWrites.cancel(initiativeId);
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
