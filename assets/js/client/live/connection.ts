// The tab's one live connection (m04.01 items 3.7 and 1.5).
//
// Created once at boot, held outside React, and never torn down by a route
// change: a screen unmounting must not drop the live session, the channel or
// (later) the user's presence (guardrail §7.4). Subscriptions are refcounted
// and released on a short grace timer, so walking from one Initiative to
// another and straight back re-uses the channel that is already joined instead
// of leaving and re-joining it.
//
// The transport is injected (`transport.ts`), so everything here — the
// refcounting, the grace, the state mapping, the delta fan-out — is exercised
// by `node --test` against a fake socket. `phoenix_transport.ts` is the real one.
//
// A joined Initiative's channel carries one `delta` per committed change
// (m04.03 1.3). It is checked (`envelope.ts`) and handed up whole; what to do
// with it — apply, hold, drop, re-read — is the sync session's call
// (`refresh.ts`), not the socket's. The join reply carries the Initiative's
// `seq` (m04.03 3.3) and is handed up the same way, on the first join and on
// every rejoin Phoenix sends after a drop — for every joined channel, a held
// one and one still in its leave grace alike.
//
// Presence (m04.02 item 3.4.2) rides the same channel: the server's
// `presence_state` / `presence_diff` are handed up as they arrive, and the
// user's own selection is announced with `select`. The last selection announced
// per Initiative is remembered here and re-sent on every join — a screen that
// mounts before its channel is up, and a socket that comes back after a drop,
// both end with the server knowing what this window has selected.

import type { ConnectionStatus } from "../state/recovery.ts";
import type { LinkState } from "./connection_state.ts";
import { initialLinkState, nextLinkState, reconnectDelayMs } from "./connection_state.ts";
import type { NetworkSignal } from "./network.ts";
import { browserNetwork } from "./network.ts";
import type { DeltaEnvelope } from "./envelope.ts";
import { parseDelta } from "./envelope.ts";
import type { LiveChannel, LiveTransport, TransportFactory } from "./transport.ts";

export interface Timers {
  setTimeout(callback: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

/** A notification row, as `DoItWeb.Api.NotificationView` serialises it. */
export interface NotificationPush {
  readonly id: number;
  readonly kind: string;
  readonly line: string;
  readonly href: string;
  readonly read: boolean;
  readonly inserted_at: string;
}

/** A presence push on a joined Initiative, as Phoenix sent it. */
export type PresenceEvent =
  /** Everyone here now — `{[user_id]: {metas: [...]}}`. */
  | { readonly kind: "state"; readonly payload: unknown }
  /** Who came and went — `{joins, leaves}` in the same shape. */
  | { readonly kind: "diff"; readonly payload: unknown };

export interface ConnectionDeps {
  transport: TransportFactory;
  /** Called whenever the reported status changes. */
  onStatus(status: ConnectionStatus): void;
  /** Called for every well-formed `delta` push on a joined Initiative. */
  onDelta(envelope: DeltaEnvelope): void;
  /**
   * Called with the `seq` in every successful join reply — the first join and
   * each rejoin after a drop. Not called when the reply carries none.
   */
  onJoined?(initiativeId: number, seq: number): void;
  /**
   * Called when the server says this user may no longer see an Initiative they
   * were watching. The channel is already gone by then — this is the client's
   * cue to stop showing what it has.
   */
  onAccessRevoked(initiativeId: number): void;
  /** Called for every `presence_state` / `presence_diff` on a joined Initiative. */
  onPresence?(initiativeId: number, event: PresenceEvent): void;
  /**
   * Called for every notification the server pushes on the user's own channel
   * (item 4.6.2). Malformed pushes never get here.
   */
  onNotification?(row: NotificationPush): void;
  /** Injected in tests so the backoff jitter is assertable. */
  random?: () => number;
  /** How long a released subscription is kept joined. */
  leaveGraceMs?: number;
  /** "Has this machine a network?" Injected in tests; the window by default. */
  network?: NetworkSignal;
  timers?: Timers;
}

export interface Connection {
  /** Stable for the life of the tab; a new value means something recreated it. */
  readonly id: string;
  status(): ConnectionStatus;
  /** Opens the socket. Idempotent — only a real reconnect moves the counter. */
  connect(): void;
  /**
   * Joins this user's own channel for the life of the tab. Idempotent, and
   * never released by a route change: what happens TO you is not something you
   * stop caring about because you walked to another screen.
   */
  watchUser(userId: number): void;
  /** Subscribing twice to the same Initiative refcounts; it never re-joins. */
  subscribeInitiative(id: number): void;
  /** Releases one hold. The channel is left after the grace period. */
  unsubscribeInitiative(id: number): void;
  /**
   * Announces what this window has selected in an Initiative (`null` for
   * nothing). Sent at once when the channel is joined, and remembered either
   * way, so a join that lands later — or again, after a reconnect — carries it.
   * Never waited on: the selection has already painted (§6.5).
   */
  select(initiativeId: number, taskId: number | null): void;
  /** Currently held Initiative ids, in subscribe order. */
  subscriptions(): readonly number[];
  /** Initiative ids whose channel is still joined (held or still in grace). */
  joined(): readonly number[];
  /** Drops the live session and everything on it. */
  disconnect(): void;
  /** Resume after the client gave up. Only meaningful when `offline`. */
  retry(): void;
  /**
   * How many times this connection has been established. It must still read 1
   * after any amount of navigating — a second connect means the live session,
   * and the user's presence with it, was dropped and rebuilt.
   */
  connectCount(): number;
}

/** Long enough to cover a route change, short enough to not leak a channel. */
export const DEFAULT_LEAVE_GRACE_MS = 5_000;

interface Subscription {
  channel: LiveChannel;
  refs: number;
  leaveHandle: unknown;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

/** A `notification` payload, or `null` when the server said something we don't know. */
export function parseNotification(payload: unknown): NotificationPush | null {
  if (!isRecord(payload)) return null;
  const { id, kind, line, href, read, inserted_at: insertedAt } = payload;
  if (typeof id !== "number") return null;
  if (typeof kind !== "string" || typeof line !== "string" || typeof href !== "string") return null;
  if (typeof read !== "boolean" || typeof insertedAt !== "string") return null;
  return { id, kind, line, href, read, inserted_at: insertedAt };
}

/** The `seq` a join reply carries, or `null` when it carries none. */
export function joinSeq(response: unknown): number | null {
  if (!isRecord(response)) return null;
  const seq = response["seq"];
  return typeof seq === "number" && Number.isInteger(seq) && seq >= 0 ? seq : null;
}

let nextConnectionId = 0;

export function createConnection(deps: ConnectionDeps): Connection {
  nextConnectionId += 1;
  const id = `conn-${nextConnectionId}`;
  const grace = deps.leaveGraceMs ?? DEFAULT_LEAVE_GRACE_MS;
  const timers: Timers = deps.timers ?? {
    setTimeout: (callback, ms) => globalThis.setTimeout(callback, ms),
    clearTimeout: (handle) => globalThis.clearTimeout(handle as number),
  };

  const subscriptions = new Map<number, Subscription>();
  // What this window last said it had selected, per Initiative. Kept apart
  // from `subscriptions`: a screen can announce before its channel exists.
  const selections = new Map<number, number | null>();
  // The user's own channel. Not in `subscriptions`: it is not refcounted, not
  // released on a route change, and it carries a different event.
  let userChannel: { id: number; channel: LiveChannel } | null = null;
  let link: LinkState = initialLinkState;
  let connects = 0;
  // Set when the retry budget runs out. Only `retry()` clears it: a route
  // change must not quietly resurrect a connection the client has told the
  // user it gave up on.
  let gaveUp = false;
  // Set by `disconnect()` and never cleared: the network watcher is gone and
  // every channel has been left, so `retry()` reaching this point would stand
  // a socket back up with nothing wired to it.
  let disposed = false;

  const report = (next: LinkState) => {
    const before = link.status;
    link = next;
    if (link.status !== before) deps.onStatus(link.status);
  };

  const transport = deps.transport({
    // Phoenix calls this once per scheduled attempt, which is the only honest
    // attempt counter the socket offers: a single failed attempt fires both
    // `onerror` and `onclose`, so counting those would spend the budget twice
    // as fast as it looks.
    reconnectAfterMs: (tries) => {
      const before = link;
      report(nextLinkState(before, { kind: "attempt", tries }));
      if (link.exhausted && !before.exhausted) {
        gaveUp = true;
        // Stop Phoenix's retry loop rather than let it spin behind a screen
        // that says we have stopped — but not from inside this hook, which
        // runs *while* the next attempt is being scheduled and would have its
        // teardown undone by the scheduling that follows. By the time this
        // fires the user may already have hit Retry, and tearing down the
        // connection they just asked for would be the worst of both.
        timers.setTimeout(() => {
          if (gaveUp) transport.disconnect();
        }, 0);
      }
      return reconnectDelayMs(tries, deps.random);
    },
  });

  transport.onOpen(() => {
    report(nextLinkState(link, { kind: "open" }));
  });

  // Says only "not live". The counting lives in `reconnectAfterMs` above.
  const dropped = () => {
    report(nextLinkState(link, { kind: "drop" }));
  };

  transport.onClose(dropped);
  transport.onError(dropped);

  // The browser losing its network is not something to wait out: the socket
  // would take a heartbeat to notice, and the badge would read "Live" the whole
  // time. Treated exactly like the budget running out — stopped, and one click
  // from trying again. Coming back online is NOT a resume: one rule for the way
  // back, and it is the user's (spec §7).
  const network = deps.network ?? browserNetwork();
  const stopWatchingNetwork = network.subscribe((online) => {
    if (online) return;
    if (link.status === "offline" && link.exhausted) return;
    gaveUp = true;
    report(nextLinkState(link, { kind: "down" }));
    transport.disconnect();
  });

  // Idempotent: only a connection that is actually down is stood back up, so
  // navigating (which subscribes) can never cost a reconnect — and a client
  // that gave up stays given up until the user says otherwise.
  const connect = () => {
    if (gaveUp) return;
    if (connects > 0 && link.status !== "offline") return;
    // A tab booting (or navigating) with no network at all would otherwise
    // sit on "Connecting…" through the whole retry schedule before the socket
    // ever notices. Same path a network loss takes mid-session: say so now,
    // and leave the way back to the user's own click (spec §7).
    if (!network.online()) {
      gaveUp = true;
      report(nextLinkState(link, { kind: "down" }));
      return;
    }
    if (link.status === "offline") report(nextLinkState(link, { kind: "retry" }));
    connects += 1;
    transport.connect();
  };

  const join = (initiativeId: number): Subscription => {
    const channel = transport.channel(`initiative:${initiativeId}`);
    channel.on("delta", (payload) => {
      // A malformed envelope is dropped whole; the gap it leaves is the
      // session's to heal with a fresh snapshot.
      const envelope = parseDelta(initiativeId, payload);
      if (envelope !== null) deps.onDelta(envelope);
    });
    channel.on("access_revoked", () => {
      // The server has already stopped the channel; drop our side of it and
      // tell the app, which owns what the user sees.
      const entry = subscriptions.get(initiativeId);
      if (entry) leave(initiativeId, entry);
      deps.onAccessRevoked(initiativeId);
    });
    channel.on("presence_state", (payload) => {
      deps.onPresence?.(initiativeId, { kind: "state", payload });
    });
    channel.on("presence_diff", (payload) => {
      deps.onPresence?.(initiativeId, { kind: "diff", payload });
    });
    channel.join((result) => {
      // Arc 3 owns what a refused or timed-out join tells the user; today the
      // reads still work, so a failed join must not take the screen down.
      if (!result.ok) return;
      // Where the server stands now: the sync decides whether we are behind.
      const seq = joinSeq(result.response);
      if (seq !== null) deps.onJoined?.(initiativeId, seq);
      // Every join — the first, and each one Phoenix re-sends after a drop —
      // tracks this window afresh with nothing selected. Say again what it has.
      const selected = selections.get(initiativeId) ?? null;
      if (selected !== null) channel.push("select", { task_id: selected });
    });
    return { channel, refs: 0, leaveHandle: null };
  };

  const leave = (initiativeId: number, entry: Subscription) => {
    if (entry.leaveHandle !== null) timers.clearTimeout(entry.leaveHandle);
    entry.channel.leave();
    subscriptions.delete(initiativeId);
  };

  return {
    id,
    status: () => link.status,
    connect,

    watchUser(userId) {
      connect();
      if (userChannel !== null) return;
      const channel = transport.channel(`user:${userId}`);
      channel.on("notification", (payload) => {
        const row = parseNotification(payload);
        if (row !== null) deps.onNotification?.(row);
      });
      channel.join(() => {
        // A refused join is not the screen's problem: the bell's read still
        // works, it just will not update live until the socket comes back.
      });
      userChannel = { id: userId, channel };
    },

    subscribeInitiative(initiativeId) {
      connect();
      const existing = subscriptions.get(initiativeId);
      if (existing) {
        if (existing.leaveHandle !== null) {
          timers.clearTimeout(existing.leaveHandle);
          existing.leaveHandle = null;
        }
        existing.refs += 1;
        return;
      }
      const entry = join(initiativeId);
      entry.refs = 1;
      subscriptions.set(initiativeId, entry);
    },

    unsubscribeInitiative(initiativeId) {
      const entry = subscriptions.get(initiativeId);
      if (!entry || entry.refs === 0) return;
      entry.refs -= 1;
      if (entry.refs > 0) return;
      // Keep the channel a moment: a route change releases the old screen's
      // hold before the new screen takes its own, and coming straight back
      // must not cost a leave/join round trip (§7.4).
      entry.leaveHandle = timers.setTimeout(() => {
        const current = subscriptions.get(initiativeId);
        if (current && current.refs === 0) {
          current.channel.leave();
          subscriptions.delete(initiativeId);
        }
      }, grace);
    },

    select(initiativeId, taskId) {
      if (selections.get(initiativeId) === taskId) return;
      selections.set(initiativeId, taskId);
      subscriptions.get(initiativeId)?.channel.push("select", { task_id: taskId });
    },

    subscriptions: () =>
      [...subscriptions.entries()].filter(([, entry]) => entry.refs > 0).map(([key]) => key),

    joined: () => [...subscriptions.keys()],

    disconnect() {
      disposed = true;
      stopWatchingNetwork();
      if (userChannel !== null) {
        userChannel.channel.leave();
        userChannel = null;
      }
      for (const [initiativeId, entry] of [...subscriptions.entries()]) {
        leave(initiativeId, entry);
      }
      report(nextLinkState(link, { kind: "down" }));
      transport.disconnect();
    },

    // The way back from `offline`: the client stopped on its own budget, so
    // resuming is the user's call and it is one click (spec §7).
    retry() {
      if (disposed) return;
      if (link.status !== "offline") return;
      gaveUp = false;
      connect();
    },

    connectCount: () => connects,
  };
}

let instance: Connection | null = null;

/**
 * Builds the tab's one connection, or hands back the one already built. Called
 * from `app.tsx` once identity is known — a signed-out tab opens no socket.
 */
export function initConnection(deps: ConnectionDeps): Connection {
  if (instance === null) instance = createConnection(deps);
  return instance;
}

/** The connection built by `initConnection`. */
export function getConnection(): Connection {
  if (instance === null) throw new Error("getConnection was called before initConnection.");
  return instance;
}

/** Test-only: forgets the singleton so a suite can start from a clean tab. */
export function resetConnection(): void {
  instance = null;
}
