// What the connection needs from a socket, and nothing more (m04.01 item 1.5).
//
// The Phoenix socket lives behind this interface so `connection.ts` — the
// refcounting, the leave grace, the state mapping — is unit-testable under
// `node --test` with a fake, and so swapping transports is a file, not a
// rewrite. The real implementation is `phoenix_transport.ts`.

export interface LiveChannel {
  /** Register a handler for a server push. */
  on(event: string, callback: (payload: unknown) => void): void;
  /** Join the topic. `callback` is called once with the outcome. */
  join(callback: (result: { ok: boolean; response: unknown }) => void): void;
  /** Leave the topic. Leaving something already left is a no-op. */
  leave(): void;
}

export interface LiveTransport {
  connect(): void;
  disconnect(): void;
  onOpen(callback: () => void): void;
  onClose(callback: () => void): void;
  onError(callback: () => void): void;
  channel(topic: string): LiveChannel;
}

export interface TransportOptions {
  /** Backoff for attempt `tries` (1-based), in milliseconds. */
  reconnectAfterMs(tries: number): number;
}

export type TransportFactory = (options: TransportOptions) => LiveTransport;
