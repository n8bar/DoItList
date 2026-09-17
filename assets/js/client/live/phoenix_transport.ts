// The real socket (m04.01 item 1.5).
//
// The only file in the client that knows Phoenix exists. It carries no
// credential: the session cookie the browser already sends on the handshake is
// the credential (spec §12), and `DoItWeb.UserSocket` reads the user from the
// session, never from params. The one param is `_csrf_token`, which is not a
// credential either — Phoenix refuses to hand a socket the session at all
// without it, exactly as it does for LiveView. It is read fresh on every
// (re)connect so a session refresh mid-tab does not strand the socket.
//
// Both transports are left on: a network that blocks WebSockets falls back to
// long-polling on its own, so "live" is not a privilege of friendly networks
// (UX_GUARDRAILS §6.9).

import { Socket } from "phoenix";

import type { LiveChannel, LiveTransport, TransportOptions } from "./transport.ts";

export function phoenixTransport(
  options: TransportOptions,
  csrfToken: () => string,
): LiveTransport {
  const socket = new Socket("/socket", {
    params: () => ({ _csrf_token: csrfToken() }),
    reconnectAfterMs: (tries: number) => options.reconnectAfterMs(tries),
  });

  // `connect(params)` is Phoenix's deprecated legacy form, and anything passed
  // there REPLACES the socket's own params — including the CSRF token above,
  // which is the difference between a live socket and a refused handshake. Its
  // signature still types the argument as required, hence the cast: we must
  // call it with nothing at all.
  const connectSocket = socket.connect.bind(socket) as unknown as () => void;

  return {
    connect: connectSocket,
    // `disconnect` takes a callback plus a close code and reason (1000 — we
    // meant to hang up).
    disconnect: () => socket.disconnect(() => {}, 1000, "client disconnected"),
    onOpen: (callback) => socket.onOpen(callback),
    onClose: (callback) => socket.onClose(callback),
    onError: (callback) => socket.onError(callback),
    channel: (topic): LiveChannel => {
      const channel = socket.channel(topic, {});
      return {
        on: (event, callback) => channel.on(event, callback),
        join: (callback) => {
          channel
            .join()
            .receive("ok", (response: unknown) => callback({ ok: true, response }))
            .receive("error", (response: unknown) => callback({ ok: false, response }))
            .receive("timeout", (response: unknown) => callback({ ok: false, response }));
        },
        push: (event, payload) => {
          channel.push(event, payload as object);
        },
        leave: () => {
          channel.leave();
        },
      };
    },
  };
}
