// A socket that never leaves the test process (m04.01 item 1.5).
//
// Test-only, but it lives beside the code it fakes so the two stay in step: if
// `LiveTransport` grows a method, this stops compiling.

import type { LiveChannel, LiveTransport, TransportOptions } from "./transport.ts";

export interface FakeChannel extends LiveChannel {
  readonly topic: string;
  joins: number;
  leaves: number;
  /** What the client sent, in order. */
  readonly pushes: Array<{ event: string; payload: unknown }>;
  /** Push a server event at whoever is listening. */
  emit(event: string, payload: unknown): void;
  /** The socket came back and Phoenix re-sent the join: the callback fires again. */
  rejoin(): void;
}

export interface FakeTransport extends LiveTransport {
  connects: number;
  disconnects: number;
  readonly channels: FakeChannel[];
  readonly options: TransportOptions;
  /** Scheduled reconnect attempts so far, i.e. Phoenix's `tries`. */
  tries: number;
  /** The delays the socket asked for, in order. */
  readonly delays: number[];
  open(): void;
  /**
   * One failed connect attempt, in Phoenix's real order: `onerror`, then the
   * retry is scheduled (`reconnectAfterMs`), then `onclose`. Both callbacks
   * fire for ONE attempt — a fake that fires them separately hides a budget
   * that is spent twice as fast as it reads.
   */
  fail(): void;
  /** A close with no preceding error (a server hanging up mid-session). */
  close(): void;
}

export function fakeTransport(): { factory: (o: TransportOptions) => LiveTransport; get(): FakeTransport } {
  let built: FakeTransport | null = null;

  const factory = (options: TransportOptions): LiveTransport => {
    const handlers: Record<"open" | "close" | "error", Array<() => void>> = {
      open: [],
      close: [],
      error: [],
    };
    const channels: FakeChannel[] = [];

    const transport: FakeTransport = {
      connects: 0,
      disconnects: 0,
      channels,
      options,
      connect() {
        transport.connects += 1;
      },
      disconnect() {
        transport.disconnects += 1;
      },
      onOpen: (callback) => handlers.open.push(callback),
      onClose: (callback) => handlers.close.push(callback),
      onError: (callback) => handlers.error.push(callback),
      channel(topic) {
        const listeners = new Map<string, Array<(payload: unknown) => void>>();
        let joined: ((result: { ok: boolean; response: unknown }) => void) | null = null;
        const channel: FakeChannel = {
          topic,
          joins: 0,
          leaves: 0,
          pushes: [],
          on(event, callback) {
            const list = listeners.get(event) ?? [];
            list.push(callback);
            listeners.set(event, list);
          },
          join(callback) {
            channel.joins += 1;
            joined = callback;
            callback({ ok: true, response: { initiative_id: topic } });
          },
          push(event, payload) {
            channel.pushes.push({ event, payload });
          },
          leave() {
            channel.leaves += 1;
          },
          rejoin() {
            channel.joins += 1;
            joined?.({ ok: true, response: { initiative_id: topic } });
          },
          emit(event, payload) {
            for (const callback of listeners.get(event) ?? []) callback(payload);
          },
        };
        channels.push(channel);
        return channel;
      },
      tries: 0,
      delays: [],
      open: () => {
        transport.tries = 0;
        handlers.open.forEach((callback) => callback());
      },
      fail: () => {
        handlers.error.forEach((callback) => callback());
        transport.tries += 1;
        transport.delays.push(options.reconnectAfterMs(transport.tries));
        handlers.close.forEach((callback) => callback());
      },
      close: () => {
        transport.tries += 1;
        transport.delays.push(options.reconnectAfterMs(transport.tries));
        handlers.close.forEach((callback) => callback());
      },
    };

    built = transport;
    return transport;
  };

  return {
    factory,
    get() {
      if (built === null) throw new Error("the transport was never built");
      return built;
    },
  };
}

/** Timers a test drives by hand. */
export function fakeTimers() {
  const pending = new Map<number, () => void>();
  let next = 0;

  return {
    timers: {
      setTimeout(callback: () => void) {
        next += 1;
        pending.set(next, callback);
        return next;
      },
      clearTimeout(handle: unknown) {
        pending.delete(handle as number);
      },
    },
    pendingCount: () => pending.size,
    /** Fire every timer that is currently due. */
    flush() {
      const due = [...pending.entries()];
      pending.clear();
      for (const [, callback] of due) callback();
    },
  };
}
