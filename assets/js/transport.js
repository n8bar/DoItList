// Transport bootstrap: un-pin a tab that Phoenix memorized onto long-poll.
//
// Phoenix's client remembers a long-poll fallback in
// sessionStorage["phx:fallback:LongPoll"] and, once set, connects straight to
// long-poll for the tab's whole life (phoenix.js `fallback("memorized")`) —
// it never probes the websocket again. One slow first handshake pins the tab,
// and long-poll is where join timeouts and recovery refreshes come from.
//
// DOM-free so `transport_test.mjs` can run it under Node; app.js supplies the
// storage, the probe, and the connect.

export const FALLBACK_KEY = "phx:fallback:LongPoll"
export const PROBE_TIMEOUT_MS = 2000

export function fallbackMemorized(storage) {
  try {
    return Boolean(storage && storage.getItem(FALLBACK_KEY))
  } catch (_e) {
    return false
  }
}

// Mirrors phoenix.js `Socket.endPointURL()`: the LiveSocket's connect params
// (`_csrf_token`) then `vsn`, on `/live/websocket`, scheme from the page.
export function probeUrl(loc, csrfToken) {
  const scheme = loc.protocol === "https:" ? "wss" : "ws"
  return `${scheme}://${loc.host}/live/websocket?_csrf_token=${encodeURIComponent(csrfToken)}&vsn=2.0.0`
}

// Opens one throwaway socket. Resolves true if it opens within `timeoutMs`,
// false on error, close-before-open, or timeout. Never rejects.
export function probeWebSocket(url, WebSocketImpl, timeoutMs = PROBE_TIMEOUT_MS) {
  return new Promise(resolve => {
    let done = false
    const finish = ok => {
      if (done) return
      done = true
      clearTimeout(timer)
      try { ws.close() } catch (_e) { /* already dead */ }
      resolve(ok)
    }
    const timer = setTimeout(() => finish(false), timeoutMs)
    let ws
    try {
      ws = new WebSocketImpl(url)
    } catch (_e) {
      clearTimeout(timer)
      resolve(false)
      return
    }
    ws.onopen = () => finish(true)
    ws.onerror = () => finish(false)
    ws.onclose = () => finish(false)
  })
}

// Without the flag: `connect()` runs synchronously and no probe is made. With
// it: probe first; clear the flag if the websocket opened; then connect (over
// the websocket if cleared, else memorized long-poll as before). Resolves to
// whether the flag was cleared.
export function connectAfterReprobe(storage, probe, connect) {
  if (!fallbackMemorized(storage)) {
    connect()
    return Promise.resolve(false)
  }
  return probe().then(open => {
    if (open) storage.removeItem(FALLBACK_KEY)
    connect()
    return open
  })
}
