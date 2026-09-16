#!/usr/bin/env node
// The CDP harness (m04.01 item 1.4): drive a REAL browser through the real
// client at `/app` and report PASS/FAIL.
//
// This is opt-in. It is NOT part of `mix test` or `mix precommit` — it needs a
// browser and a signed-in session, neither of which the suite has.
//
//   CDP_URL       DevTools endpoint          (default http://localhost:9222)
//   APP_URL       app origin                 (default http://localhost:4000)
//   CDP_OPTIONAL  =1 → exit 0 when no endpoint answers (default: exit 2)
//   CDP_REUSE_TAB =1 → fall back to an existing page target if /json/new fails
//
// It runs from the HOST: the container cannot reach the operator's bridge.
// Node 22+ (or Node 20 with --experimental-websocket) — it needs global WebSocket.
//
// Every check is one exported async function taking the shared context, listed
// in CHECKS below. Worklist 4 adds the narrow-viewport hamburger check by
// writing a function here and adding one line to CHECKS — see the marker.

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  browserVersion,
  clickElement,
  closeTarget,
  connect,
  evaluate,
  listTargets,
  openTarget,
  waitFor,
} from "./cdp.mjs";

const CDP_URL = (process.env.CDP_URL ?? "http://localhost:9222").replace(/\/$/, "");
const APP_URL = (process.env.APP_URL ?? "http://localhost:4000").replace(/\/$/, "");
const VIEWPORT = { width: 1280, height: 800 };
const READY_TIMEOUT_MS = 15_000;
const SHOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../../tmp/cdp");

// ---------------------------------------------------------------------------
// Checks. One exported async function each; `ctx` carries the session and the
// scratch space checks share (rects measured by an earlier check, etc).
// ---------------------------------------------------------------------------

/** The client came up and the chrome we ship today is on the glass. */
export async function checkClientReady(ctx) {
  const { session } = ctx;

  await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives` });
  await waitFor(session, "return window.__doit_client_ready === true;", {
    timeoutMs: READY_TIMEOUT_MS,
    what: "window.__doit_client_ready",
  });

  const chrome = await evaluate(
    session,
    `
    const ids = ["client-header", "client-nav-initiatives", "client-nav-assigned", "client-nav-account"];
    const missing = ids.filter((id) => document.getElementById(id) === null);
    const heading = document.getElementById("route-heading");
    return {
      missing,
      path: location.pathname,
      heading: heading === null ? null : heading.textContent.trim(),
    };
  `,
  );

  if (chrome.missing.length > 0) throw new Error(`chrome missing: #${chrome.missing.join(", #")}`);
  if (chrome.path !== "/app/initiatives") throw new Error(`path is ${chrome.path}`);
  if (chrome.heading !== "Initiatives") throw new Error(`heading is ${chrome.heading}`);

  // The baseline for the layout-shift check: measured the instant the client
  // said it was ready, BEFORE the Initiatives read has come back.
  ctx.rectsAtReady = await measureChrome(session);
  return `heading "${chrome.heading}", nav present`;
}

/**
 * The chrome must not move when the content lands underneath it. Worklist 4
 * extends this to the rail.
 */
export async function checkNoLayoutShift(ctx) {
  const { session } = ctx;

  // "Settled" = the loading status is gone and something took its place: rows,
  // the empty-state line, or the in-place error.
  const settled = await waitFor(
    session,
    `
    const main = document.getElementById("client-main");
    if (main === null) return null;
    if (main.querySelector('[role="status"]') !== null) return null;
    if (main.querySelector("#initiatives-list li") !== null) return "rows";
    if (main.querySelector("#screen-error") !== null) return "error";
    if (main.querySelector("section p") !== null) return "empty";
    return null;
  `,
    { timeoutMs: READY_TIMEOUT_MS, what: "the Initiatives list to settle" },
  );

  const after = await measureChrome(session);
  const moved = shifted(ctx.rectsAtReady, after);
  if (moved.length > 0) {
    throw new Error(`layout shifted after content arrived: ${moved.join("; ")}`);
  }
  const rows = await evaluate(
    session,
    `return document.querySelectorAll("#initiatives-list li").length;`,
  );
  return `${settled} (${rows} rows), header and nav did not move`;
}

/** ONE real interaction: click the Account nav link like a person would. */
export async function checkNavClickToAccount(ctx) {
  const { session } = ctx;

  const at = await clickElement(session, "#client-nav-account");
  const landed = await waitFor(
    session,
    `
    const heading = document.getElementById("route-heading");
    if (location.pathname !== "/app/account") return null;
    if (heading === null || heading.textContent.trim() !== "Account") return null;
    return {
      path: location.pathname,
      focused: document.activeElement === null ? null : document.activeElement.id,
      current: document.getElementById("client-nav-account").getAttribute("aria-current"),
    };
  `,
    { timeoutMs: 5_000, what: "the Account route" },
  );

  if (landed.focused !== "route-heading") {
    throw new Error(`focus went to "${landed.focused ?? "(none)"}", not the route heading`);
  }
  if (landed.current !== "page") throw new Error("the Account nav link is not aria-current=page");
  return `clicked at (${at.x},${at.y}) → ${landed.path}, focus on the heading`;
}

// WORKLIST 4 ADDS ITS CHECKS HERE (narrow-viewport hamburger, rail layout
// stability). Write an `export async function checkX(ctx)` above and add it to
// CHECKS below — nothing else in this file needs to change.

const CHECKS = [
  ["client ready", checkClientReady],
  ["no layout shift", checkNoLayoutShift],
  ["nav click → Account", checkNavClickToAccount],
];

// ---------------------------------------------------------------------------
// Measurement helpers.
// ---------------------------------------------------------------------------

async function measureChrome(session) {
  return evaluate(
    session,
    `
    const box = (el) => {
      if (el === null) return null;
      const r = el.getBoundingClientRect();
      return { x: Math.round(r.x), y: Math.round(r.y), w: Math.round(r.width), h: Math.round(r.height) };
    };
    return {
      header: box(document.getElementById("client-header")),
      nav: box(document.querySelector("#client-header nav")),
    };
  `,
  );
}

/** Which measured boxes moved or resized between two samples. */
function shifted(before, after) {
  const moved = [];
  for (const key of Object.keys(before ?? {})) {
    const a = before[key];
    const b = after?.[key];
    if (a === null || b == null) {
      moved.push(`${key} disappeared`);
      continue;
    }
    if (a.x !== b.x || a.y !== b.y || a.w !== b.w || a.h !== b.h) {
      moved.push(`${key} ${JSON.stringify(a)} → ${JSON.stringify(b)}`);
    }
  }
  return moved;
}

async function screenshot(session, name) {
  try {
    const { data } = await session.send("Page.captureScreenshot", { format: "png" });
    await mkdir(SHOT_DIR, { recursive: true });
    const path = resolve(SHOT_DIR, `${name}-${Date.now()}.png`);
    await writeFile(path, Buffer.from(data, "base64"));
    return path;
  } catch (error) {
    return `(screenshot failed: ${error.message})`;
  }
}

// ---------------------------------------------------------------------------
// Target acquisition. We open our OWN tab and close it; the operator's tabs are
// never touched unless CDP_REUSE_TAB says so explicitly.
// ---------------------------------------------------------------------------

/**
 * Get a target AND a live session on it, as one step that cannot leak.
 *
 * Opening a tab and attaching to it are two operations against a REAL browser:
 * if the attach fails (handshake refused, timeout), the tab we just opened is
 * still sitting in the operator's window. So the failure path closes it. The
 * browser calls are injected so the leak rule is unit-testable — see
 * `check_client.test.mjs`.
 */
export async function acquireSession({ acquire, attach, release }) {
  const target = await acquire();
  try {
    return { target, session: await attach(target.webSocketDebuggerUrl) };
  } catch (error) {
    if (target.ours) await release(target.id).catch(() => {});
    throw error;
  }
}

async function acquireTarget() {
  try {
    const target = await openTarget(CDP_URL, "about:blank");
    if (target?.webSocketDebuggerUrl) return { ...target, ours: true };
    throw new Error("no webSocketDebuggerUrl in the /json/new reply");
  } catch (error) {
    if (process.env.CDP_REUSE_TAB !== "1") {
      throw new Error(
        `could not open a tab (${error.message}). Set CDP_REUSE_TAB=1 to drive an existing tab instead — that navigates a tab the operator is using.`,
      );
    }
    const page = (await listTargets(CDP_URL)).find(
      (t) => t.type === "page" && t.webSocketDebuggerUrl,
    );
    if (page === undefined) throw new Error("no page target to reuse");
    process.stdout.write(`note  reusing the operator's tab: ${page.url}\n`);
    return { ...page, ours: false };
  }
}

// ---------------------------------------------------------------------------

async function main() {
  let version;
  try {
    version = await browserVersion(CDP_URL);
  } catch (error) {
    const message = `no CDP endpoint at ${CDP_URL} — skipped (${error.message})`;
    process.stdout.write(`${message}\n`);
    process.exit(process.env.CDP_OPTIONAL === "1" ? 0 : 2);
  }

  process.stdout.write(`cdp   ${CDP_URL} → ${version.Browser}\n`);
  process.stdout.write(`app   ${APP_URL}\n`);

  const { target, session } = await acquireSession({
    acquire: acquireTarget,
    attach: (wsUrl) => connect(wsUrl),
    release: (id) => closeTarget(CDP_URL, id),
  });
  const ctx = { session, appUrl: APP_URL };
  const results = [];
  let failed = false;

  try {
    await session.send("Page.enable");
    await session.send("Runtime.enable");
    await session.send("Emulation.setDeviceMetricsOverride", {
      ...VIEWPORT,
      deviceScaleFactor: 1,
      mobile: false,
    });

    for (const [name, check] of CHECKS) {
      const started = Date.now();
      if (failed) {
        results.push({ name, status: "SKIP", ms: 0, note: "an earlier check failed" });
        continue;
      }
      try {
        const note = await check(ctx);
        results.push({ name, status: "PASS", ms: Date.now() - started, note });
      } catch (error) {
        failed = true;
        const shot = await screenshot(session, name.replace(/\W+/g, "-"));
        results.push({ name, status: "FAIL", ms: Date.now() - started, note: error.message, shot });
      }
    }
  } finally {
    session.close();
    if (target.ours) await closeTarget(CDP_URL, target.id).catch(() => {});
  }

  process.stdout.write("\n");
  for (const r of results) {
    process.stdout.write(`${r.status.padEnd(4)}  ${String(r.ms).padStart(6)}ms  ${r.name}\n`);
    if (r.note) process.stdout.write(`                      ${r.note}\n`);
    if (r.shot) process.stdout.write(`                      screenshot: ${r.shot}\n`);
  }
  const passed = results.filter((r) => r.status === "PASS").length;
  process.stdout.write(`\n${passed}/${results.length} checks passed\n`);
  process.exit(failed ? 1 : 0);
}

// Only when run as the script. Importing this file (the unit tests do) must not
// reach for a browser — and neither must `node --test bin/cdp/`, which runs
// every file in the directory, this one included.
const runAsScript =
  process.env.NODE_TEST_CONTEXT === undefined &&
  process.argv[1] !== undefined &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (runAsScript) {
  main().catch((error) => {
    process.stderr.write(`harness error: ${error.message}\n`);
    process.exit(2);
  });
}
