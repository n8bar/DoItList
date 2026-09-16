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
// refcounting, the grace, the state mapping, the refetch fan-out — is exercised
// by `node --test` against a fake socket. `phoenix_transport.ts` is the real one.

import type { ConnectionStatus } from "../state/recovery.ts";
import type { LinkState } from "./connection_state.ts";
import { initialLinkState, nextLinkState, reconnectDelayMs } from "./connection_state.ts";
import type { LiveChannel, LiveTransport, TransportFactory } from "./transport.ts";

/** The kinds of change the server announces on a joined Initiative. */
export const CHANGED_KINDS = [
  "task_created",
  "task_updated",
  "task_moved",
  "task_deleted",
  "members_changed",
] as const;

export type ChangedKind = (typeof CHANGED_KINDS)[number];

export interface ChangedEvent {
  /** The Initiative whose channel carried the event. */
  readonly initiativeId: number;
  readonly kind: ChangedKind;
  /** The record that moved — a task id, except `members_changed`. */
  readonly id: number;
}

export interface Timers {
  setTimeout(callback: () => void, ms: number): unknown;
  clearTimeout(handle: unknown): void;
}

export interface ConnectionDeps {
  transport: TransportFactory;
  /** Called whenever the reported status changes. */
  onStatus(status: ConnectionStatus): void;
  /** Called for every `changed` push on a joined Initiative. */
  onChanged(event: ChangedEvent): void;
  /**
   * Called when the server says this user may no longer see an Initiative they
   * were watching. The channel is already gone by then — this is the client's
   * cue to stop showing what it has.
   */
  onAccessRevoked(initiativeId: number): void;
  /** Injected in tests so the backoff jitter is assertable. */
  random?: () => number;
  /** How long a released subscription is kept joined. */
  leaveGraceMs?: number;
  timers?: Timers;
}

export interface Connection {
  /** Stable for the life of the tab; a new value means something recreated it. */
  readonly id: string;
  status(): ConnectionStatus;
  /** Opens the socket. Idempotent — only a real reconnect moves the counter. */
  connect(): void;
  /** Subscribing twice to the same Initiative refcounts; it never re-joins. */
  subscribeInitiative(id: number): void;
  /** Releases one hold. The channel is left after the grace period. */
  unsubscribeInitiative(id: number): void;
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

/** A `changed` payload, or `null` when the server said something we don't know. */
export function parseChanged(initiativeId: number, payload: unknown): ChangedEvent | null {
  if (!isRecord(payload)) return null;
  const { kind, id } = payload;
  if (typeof kind !== "string" || !(CHANGED_KINDS as readonly string[]).includes(kind)) return null;
  if (typeof id !== "number") return null;
  return { initiativeId, kind: kind as ChangedKind, id };
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
  let link: LinkState = initialLinkState;
  let connects = 0;
  // Set when the retry budget runs out. Only `retry()` clears it: a route
  // change must not quietly resurrect a connection the client has told the
  // user it gave up on.
  let gaveUp = false;

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

  // Idempotent: only a connection that is actually down is stood back up, so
  // navigating (which subscribes) can never cost a reconnect — and a client
  // that gave up stays given up until the user says otherwise.
  const connect = () => {
    if (gaveUp) return;
    if (connects > 0 && link.status !== "offline") return;
    if (link.status === "offline") report(nextLinkState(link, { kind: "retry" }));
    connects += 1;
    transport.connect();
  };

  const join = (initiativeId: number): Subscription => {
    const channel = transport.channel(`initiative:${initiativeId}`);
    channel.on("changed", (payload) => {
      const event = parseChanged(initiativeId, payload);
      if (event !== null) deps.onChanged(event);
    });
    channel.on("access_revoked", () => {
      // The server has already stopped the channel; drop our side of it and
      // tell the app, which owns what the user sees.
      const entry = subscriptions.get(initiativeId);
      if (entry) leave(initiativeId, entry);
      deps.onAccessRevoked(initiativeId);
    });
    channel.join(() => {
      // Arc 3 owns what a refused or timed-out join tells the user; today the
      // reads still work, so a failed join must not take the screen down.
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

    subscriptions: () =>
      [...subscriptions.entries()].filter(([, entry]) => entry.refs > 0).map(([key]) => key),

    joined: () => [...subscriptions.keys()],

    disconnect() {
      for (const [initiativeId, entry] of [...subscriptions.entries()]) {
        leave(initiativeId, entry);
      }
      report(nextLinkState(link, { kind: "down" }));
      transport.disconnect();
    },

    // The way back from `offline`: the client stopped on its own budget, so
    // resuming is the user's call and it is one click (spec §7).
    retry() {
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
