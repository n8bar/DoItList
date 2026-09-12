// Unit suite for the transport bootstrap (assets/js/transport.js).
//
//   node --test assets/js/transport_test.mjs
//
// `test/assets/transport_js_test.exs` runs this same command so `mix test`
// stays the single gate (m03.04 item 6.11.2).

import test from "node:test"
import assert from "node:assert/strict"

import {
  FALLBACK_KEY,
  fallbackMemorized,
  probeUrl,
  probeWebSocket,
  connectAfterReprobe
} from "./transport.js"

const storageWith = (entries = {}) => {
  const map = new Map(Object.entries(entries))
  return {
    getItem: k => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: k => map.delete(k),
    has: k => map.has(k)
  }
}

const pinned = () => storageWith({ [FALLBACK_KEY]: "true" })

// A WebSocket stand-in that fires `event` on the next tick (or never).
const fakeWebSocket = event =>
  class {
    constructor(url) {
      this.url = url
      this.closed = false
      if (event) setTimeout(() => this[`on${event}`] && this[`on${event}`](), 0)
    }
    close() { this.closed = true }
  }

// --- 6.11.1: the URL mirrors what the LiveSocket sends ---------------------

test("probe URL carries the csrf token and vsn on the page's scheme", () => {
  assert.equal(
    probeUrl({ protocol: "https:", host: "doitlist.app" }, "a+b/c"),
    "wss://doitlist.app/live/websocket?_csrf_token=a%2Bb%2Fc&vsn=2.0.0"
  )
  assert.equal(
    probeUrl({ protocol: "http:", host: "localhost:4000" }, "t"),
    "ws://localhost:4000/live/websocket?_csrf_token=t&vsn=2.0.0"
  )
})

test("fallbackMemorized reads the flag and tolerates a throwing store", () => {
  assert.equal(fallbackMemorized(pinned()), true)
  assert.equal(fallbackMemorized(storageWith()), false)
  assert.equal(fallbackMemorized({ getItem() { throw new Error("blocked") } }), false)
  assert.equal(fallbackMemorized(null), false)
})

// --- probeWebSocket -------------------------------------------------------

test("probe resolves true when the socket opens, and closes it", async () => {
  const WS = fakeWebSocket("open")
  assert.equal(await probeWebSocket("ws://x/live/websocket", WS, 1000), true)
})

test("probe resolves false on error", async () => {
  assert.equal(await probeWebSocket("ws://x", fakeWebSocket("error"), 1000), false)
})

test("probe resolves false on close-before-open", async () => {
  assert.equal(await probeWebSocket("ws://x", fakeWebSocket("close"), 1000), false)
})

test("probe resolves false on timeout", async () => {
  assert.equal(await probeWebSocket("ws://x", fakeWebSocket(null), 10), false)
})

test("probe resolves false when the constructor throws", async () => {
  class Throws { constructor() { throw new Error("SecurityError") } }
  assert.equal(await probeWebSocket("ws://x", Throws, 1000), false)
})

// --- 6.11.2: flag set + probe outcome; flag absent ------------------------

test("flag set + probe opens -> flag cleared, then connect", async () => {
  const storage = pinned()
  const calls = []
  const cleared = await connectAfterReprobe(
    storage,
    () => { calls.push("probe"); return Promise.resolve(true) },
    () => calls.push("connect")
  )
  assert.equal(cleared, true)
  assert.equal(storage.has(FALLBACK_KEY), false)
  assert.deepEqual(calls, ["probe", "connect"])
})

test("flag set + probe errors -> flag kept, still connects", async () => {
  const storage = pinned()
  let connected = 0
  const cleared = await connectAfterReprobe(storage, () => Promise.resolve(false), () => connected++)
  assert.equal(cleared, false)
  assert.equal(storage.getItem(FALLBACK_KEY), "true")
  assert.equal(connected, 1)
})

test("flag set + probe times out -> flag kept, still connects", async () => {
  const storage = pinned()
  let connected = 0
  const probe = () => probeWebSocket("ws://x", fakeWebSocket(null), 10)
  const cleared = await connectAfterReprobe(storage, probe, () => connected++)
  assert.equal(cleared, false)
  assert.equal(storage.getItem(FALLBACK_KEY), "true")
  assert.equal(connected, 1)
})

test("flag absent -> no probe, connect runs synchronously", async () => {
  const storage = storageWith()
  let probed = 0
  let connected = 0
  const p = connectAfterReprobe(storage, () => { probed++; return Promise.resolve(true) }, () => connected++)
  assert.equal(connected, 1, "connect must not wait on a round trip")
  assert.equal(await p, false)
  assert.equal(probed, 0)
})
