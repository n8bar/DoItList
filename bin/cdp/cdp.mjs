// A minimal Chrome DevTools Protocol client (m04.01 item 1.4).
//
// No dependencies: Node's global `WebSocket` is the whole transport. The parts
// that are easy to get subtly wrong — matching a reply to the request that
// asked for it, and failing every outstanding request when the socket dies —
// live in `createSession`, which takes an *injected* socket object. That makes
// the correlation logic unit-testable without a real browser or a real server
// (see `cdp.test.mjs`); `connect` is the thin wiring that hands it a real
// WebSocket.
//
// Only ONE CDP client may attach to a page target at a time, so every caller
// must close its session — `withSession` does that even on a throw.

/** Thrown when the browser answers a command with an error. */
export class CdpError extends Error {
  constructor(method, error) {
    super(`${method}: ${error?.message ?? "unknown CDP error"}`);
    this.name = "CdpError";
    this.code = error?.code;
    this.data = error?.data;
  }
}

/**
 * The request/response correlation layer.
 *
 * `socket` only needs `send(text)` and `close()`. Feed incoming frames in with
 * `receive(text)` and terminal socket conditions with `fail(error)`.
 */
export function createSession(socket) {
  const pending = new Map();
  const listeners = new Map();
  let nextId = 0;
  let closed = null;

  const settleAll = (error) => {
    for (const { reject } of pending.values()) reject(error);
    pending.clear();
  };

  return {
    /** Send a command; resolves with `result`, rejects with `CdpError`. */
    send(method, params = {}) {
      if (closed !== null) return Promise.reject(closed);
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        pending.set(id, { method, resolve, reject });
        try {
          socket.send(JSON.stringify({ id, method, params }));
        } catch (error) {
          pending.delete(id);
          reject(error);
        }
      });
    },

    /** Handle one inbound frame: a command reply, or an event. */
    receive(raw) {
      let message;
      try {
        message = JSON.parse(raw);
      } catch {
        return; // A frame we can't parse is not a reply we can correlate.
      }

      if (typeof message.id === "number") {
        const entry = pending.get(message.id);
        if (entry === undefined) return; // Late reply to a request we gave up on.
        pending.delete(message.id);
        if (message.error) entry.reject(new CdpError(entry.method, message.error));
        else entry.resolve(message.result ?? {});
        return;
      }

      if (typeof message.method === "string") {
        for (const handler of listeners.get(message.method) ?? []) handler(message.params ?? {});
      }
    },

    /** Subscribe to a CDP event. Returns an unsubscribe function. */
    on(method, handler) {
      const handlers = listeners.get(method) ?? new Set();
      handlers.add(handler);
      listeners.set(method, handlers);
      return () => handlers.delete(handler);
    },

    /** The socket died: every outstanding request fails, further sends fail. */
    fail(error) {
      if (closed !== null) return;
      closed = error instanceof Error ? error : new Error(String(error));
      settleAll(closed);
    },

    close() {
      this.fail(new Error("CDP session closed"));
      try {
        socket.close();
      } catch {
        // Closing an already-dead socket is not an error worth reporting.
      }
    },

    get pendingCount() {
      return pending.size;
    },
    get isClosed() {
      return closed !== null;
    },
  };
}

/** Open a CDP session against a `webSocketDebuggerUrl`. */
export function connect(wsUrl, { timeoutMs = 10_000 } = {}) {
  if (typeof WebSocket === "undefined") {
    return Promise.reject(
      new Error(
        "This Node has no global WebSocket. Use Node 22+, or re-run with --experimental-websocket.",
      ),
    );
  }

  return new Promise((resolve, reject) => {
    const socket = new WebSocket(wsUrl);
    const session = createSession(socket);
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error(`CDP connect timed out after ${timeoutMs}ms: ${wsUrl}`));
    }, timeoutMs);

    socket.addEventListener("open", () => {
      clearTimeout(timer);
      resolve(session);
    });
    socket.addEventListener("message", (event) => session.receive(String(event.data)));
    socket.addEventListener("error", () => session.fail(new Error(`CDP socket error: ${wsUrl}`)));
    socket.addEventListener("close", () => {
      clearTimeout(timer);
      session.fail(new Error("CDP socket closed"));
      reject(new Error(`CDP socket closed before open: ${wsUrl}`));
    });
  });
}

// ---------------------------------------------------------------------------
// The HTTP half of the protocol (target list, open, close).
// ---------------------------------------------------------------------------

async function httpJson(url, init) {
  const response = await fetch(url, { signal: AbortSignal.timeout(10_000), ...init });
  const text = await response.text();
  if (!response.ok) throw new Error(`${init?.method ?? "GET"} ${url} → ${response.status}: ${text}`);
  return text.trim() === "" ? null : JSON.parse(text);
}

export async function browserVersion(cdpUrl) {
  return httpJson(`${cdpUrl}/json/version`);
}

export async function listTargets(cdpUrl) {
  return (await httpJson(`${cdpUrl}/json/list`)) ?? [];
}

/** Open our own tab. Newer Chrome requires PUT; older only answers GET. */
export async function openTarget(cdpUrl, url) {
  const endpoint = `${cdpUrl}/json/new?${encodeURIComponent(url)}`;
  try {
    return await httpJson(endpoint, { method: "PUT" });
  } catch (error) {
    if (!/405|400/.test(String(error.message))) throw error;
    return httpJson(endpoint);
  }
}

export async function closeTarget(cdpUrl, id) {
  const response = await fetch(`${cdpUrl}/json/close/${id}`, {
    signal: AbortSignal.timeout(10_000),
  });
  return response.ok;
}

// ---------------------------------------------------------------------------
// Conveniences the harness leans on.
// ---------------------------------------------------------------------------

/** Evaluate an expression in the page and return its JSON value. */
export async function evaluate(session, expression) {
  const result = await session.send("Runtime.evaluate", {
    expression: `(() => { ${expression} })()`,
    returnByValue: true,
    awaitPromise: true,
  });
  if (result.exceptionDetails) {
    const thrown = result.exceptionDetails.exception?.description;
    throw new Error(`page threw: ${thrown ?? result.exceptionDetails.text}`);
  }
  return result.result?.value;
}

/** Poll `expression` until it returns a truthy value, or give up. */
export async function waitFor(session, expression, { timeoutMs = 15_000, everyMs = 100, what }) {
  const deadline = Date.now() + timeoutMs;
  let last;
  for (;;) {
    last = await evaluate(session, expression);
    if (last) return last;
    if (Date.now() > deadline) {
      throw new Error(`timed out after ${timeoutMs}ms waiting for ${what ?? expression}`);
    }
    await new Promise((resolve) => setTimeout(resolve, everyMs));
  }
}

/**
 * A REAL click: hit-test the element's rect centre, then dispatch trusted-ish
 * mouse events there. `element.click()` is a false green — it fires through
 * `disabled`, `pointer-events: none` and anything covering the target.
 */
export async function clickElement(session, selector) {
  const hit = await evaluate(
    session,
    `
    // The first match with a box: a control the layout draws once per
    // breakpoint (New List, 7.10.4) matches twice, one of them hidden.
    const all = [...document.querySelectorAll(${JSON.stringify(selector)})];
    const el = all.find((e) => e.getClientRects().length > 0) ?? all[0] ?? null;
    if (!el) return { ok: false, why: "no element matches " + ${JSON.stringify(selector)} };
    el.scrollIntoView({ block: "center", inline: "center" });
    const r = el.getBoundingClientRect();
    if (r.width === 0 || r.height === 0) return { ok: false, why: "element has no box" };
    const x = Math.round(r.left + r.width / 2);
    const y = Math.round(r.top + r.height / 2);
    const at = document.elementFromPoint(x, y);
    if (at === null) return { ok: false, why: "nothing at (" + x + "," + y + ")" };
    if (at !== el && !el.contains(at)) {
      return { ok: false, why: "point (" + x + "," + y + ") hits <" + at.tagName.toLowerCase() +
        (at.id ? "#" + at.id : "") + "> instead" };
    }
    return { ok: true, x, y };
  `,
  );

  if (!hit.ok) throw new Error(`cannot click ${selector}: ${hit.why}`);

  const base = { x: hit.x, y: hit.y, button: "left", buttons: 1, clickCount: 1 };
  await session.send("Input.dispatchMouseEvent", { type: "mouseMoved", ...base, buttons: 0 });
  await session.send("Input.dispatchMouseEvent", { type: "mousePressed", ...base });
  await session.send("Input.dispatchMouseEvent", { type: "mouseReleased", ...base });
  return hit;
}

/**
 * The halves of a mouse drag, for gestures a click cannot make. Points are
 * viewport CSS px (`getBoundingClientRect` space). `mouseGlide` moves a
 * pressed mouse from `from` to `to` in `steps` moves, so a threshold-gated
 * drag sees motion rather than one jump.
 */
export async function mouseMove(session, { x, y }, { pressed = false } = {}) {
  await session.send("Input.dispatchMouseEvent", {
    type: "mouseMoved",
    x,
    y,
    button: pressed ? "left" : "none",
    buttons: pressed ? 1 : 0,
  });
}

export async function mouseDown(session, { x, y }) {
  await session.send("Input.dispatchMouseEvent", { type: "mousePressed", x, y, button: "left", buttons: 1, clickCount: 1 });
}

export async function mouseUp(session, { x, y }) {
  await session.send("Input.dispatchMouseEvent", { type: "mouseReleased", x, y, button: "left", buttons: 0, clickCount: 1 });
}

export async function mouseGlide(session, from, to, steps = 4) {
  for (let i = 1; i <= steps; i += 1) {
    const x = Math.round(from.x + ((to.x - from.x) * i) / steps);
    const y = Math.round(from.y + ((to.y - from.y) * i) / steps);
    await mouseMove(session, { x, y }, { pressed: true });
  }
}

/** Presses one key (a "raw" down/up pair), e.g. `pressKey(session, "Escape")`. */
export async function pressKey(session, key, { code = key, windowsVirtualKeyCode = 0 } = {}) {
  const base = { key, code, windowsVirtualKeyCode, nativeVirtualKeyCode: windowsVirtualKeyCode };
  await session.send("Input.dispatchKeyEvent", { type: "rawKeyDown", ...base });
  await session.send("Input.dispatchKeyEvent", { type: "keyUp", ...base });
}
