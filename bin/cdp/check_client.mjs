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
//   CDP_FROM      =<text> → start at the first check whose name contains it
//
// It drives ONE tab: an existing one on APP_URL when there is one, else a
// fresh one — and never closes it (the operator's rule, shared with
// check_tree.mjs).
//
// It runs from the HOST: the container cannot reach the operator's bridge.
// Node 22+ (or Node 20 with --experimental-websocket) — it needs global WebSocket.
//
// Every check is one exported async function taking the shared context, listed
// in CHECKS below. Add a check by writing an `export async function checkX(ctx)`
// and adding one line to CHECKS — nothing else in this file needs to change.
//
// Order matters in one place only: the narrow-viewport check changes the
// emulated viewport, so it runs last.

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  browserVersion,
  clickElement,
  connect,
  evaluate,
  listTargets,
  mouseDown,
  mouseGlide,
  mouseMove,
  mouseUp,
  openTarget,
  pressKey,
  waitFor,
} from "./cdp.mjs";
// The tree harness's page-side stopwatch and operations helpers (7.9), shared
// so the index measures its writes the same way the tree does.
import {
  OPS_TAP,
  armStopwatch,
  assertAcknowledged,
  movedBefore,
  pageOperation,
  pageOperations,
  pickTarget,
  readStopwatch,
} from "./check_tree.mjs";
// The bell's write, from the module the browser itself bundles — so this check
// cannot assert a shape the client stopped sending (or never sent).
import { markAllReadRequest } from "../../assets/js/client/state/notification_ops.js";

const CDP_URL = (process.env.CDP_URL ?? "http://localhost:9222").replace(/\/$/, "");
const APP_URL = (process.env.APP_URL ?? "http://localhost:4000").replace(/\/$/, "");
const VIEWPORT = { width: 1280, height: 800 };
// Desktop widths where the header band is tightest: the summary took its own
// slot at `lg:` (1024px) precisely because it used to be centred ON TOP of the
// nav here, hiding Retry — the only way back from offline — and eating its
// clicks.
const CROWDED_WIDTHS = [1024, 1100, 1180, 1280];
const NARROW_VIEWPORT = { width: 390, height: 844 };
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
    const ids = [
      "client-header", "client-nav-initiatives", "client-nav-assigned",
      "client-main", "client-menu-button",
      "client-skip-link", "client-theme-toggle", "client-bell-button",
      "client-account-menu-button",
    ];
    const missing = ids.filter((id) => document.getElementById(id) === null);
    const heading = document.getElementById("route-heading");
    const shown = (el) => el !== null && el.getBoundingClientRect().width > 0;
    return {
      missing,
      path: location.pathname,
      heading: heading === null ? null : heading.textContent.trim(),
      narrowNavVisible: shown(document.getElementById("client-menu-button")),
    };
  `,
  );

  if (chrome.missing.length > 0) throw new Error(`chrome missing: #${chrome.missing.join(", #")}`);
  if (chrome.narrowNavVisible) throw new Error("the hamburger is showing at 1280px");
  if (chrome.path !== "/app/initiatives") throw new Error(`path is ${chrome.path}`);
  if (chrome.heading !== "My Initiatives") throw new Error(`heading is ${chrome.heading}`);

  // The baseline for the layout-shift check: measured the instant the client
  // said it was ready, BEFORE the Initiatives read has come back.
  ctx.rectsAtReady = await measureChrome(session);
  return `heading "${chrome.heading}", nav present`;
}

/**
 * The chrome must not move when the content lands underneath it.
 */
export async function checkNoLayoutShift(ctx) {
  const { session } = ctx;

  // "Settled" = the loading status is gone and something took its place: rows,
  // the empty-state line, or the in-place error.
  const settled = await waitFor(
    session,
    `
    const section = document.querySelector("#client-main section");
    if (section === null) return null;
    if (section.querySelector('[role="status"]') !== null) return null;
    if (section.querySelector("#initiatives > [data-initiative-id]") !== null) return "rows";
    if (section.querySelector("#screen-error") !== null) return "error";
    if (section.querySelector("#initiatives-empty") !== null) return "empty";
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
    `return document.querySelectorAll("#initiatives > [data-initiative-id]").length;`,
  );
  return `${settled} (${rows} rows), header, nav and main column did not move`;
}

/**
 * Item 4.6, MEASURED rather than declared: a skeleton row and the real row that
 * replaces it must be the same height, and the list must start where the
 * skeleton started. Both come from `LIST_ROW_HEIGHT`, and this is the check that
 * notices when they stop.
 *
 * The skeleton is short-lived on a fast link, so the read is deliberately slowed
 * to make it observable, then unslowed to let the rows land.
 */
export async function checkSkeletonMatchesRow(ctx) {
  const { session } = ctx;
  const fast = {
    offline: false,
    latency: 0,
    downloadThroughput: -1,
    uploadThroughput: -1,
  };

  await session.send("Network.enable");
  try {
    await session.send("Network.emulateNetworkConditions", { ...fast, latency: 1200 });
    await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives` });
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come up on a slow link",
    });

    const busy = await waitFor(
      session,
      `
      const skeleton = document.getElementById("initiatives-skeleton");
      if (skeleton === null) return null;
      const row = skeleton.querySelector('div[aria-hidden="true"]');
      if (row === null) return null;
      if (skeleton.getAttribute("aria-busy") !== "true") return null;
      return {
        row: Math.round(row.getBoundingClientRect().height),
        top: Math.round(skeleton.getBoundingClientRect().top),
        rows: skeleton.querySelectorAll('div[aria-hidden="true"]').length,
      };
    `,
      { timeoutMs: READY_TIMEOUT_MS, what: "the Initiatives skeleton" },
    );

    await session.send("Network.emulateNetworkConditions", fast);

    const real = await waitFor(
      session,
      `
      const list = document.getElementById("initiatives");
      const first = document.querySelector("#initiatives > [data-initiative-id]");
      if (list === null || first === null) return null;
      if (document.getElementById("initiatives-skeleton") !== null) return null;
      // The block that takes the skeleton's place starts with the Sort control
      // (shown only once there are rows), then the list.
      const block = document.getElementById("initiative-sort") ?? list;
      return {
        row: Math.round(first.getBoundingClientRect().height),
        top: Math.round(block.getBoundingClientRect().top),
        rows: list.children.length,
      };
    `,
      { timeoutMs: READY_TIMEOUT_MS, what: "the Initiatives rows" },
    );

    if (Math.abs(busy.row - real.row) > 1) {
      throw new Error(`a skeleton row is ${busy.row}px but a real row is ${real.row}px`);
    }
    if (Math.abs(busy.top - real.top) > 1) {
      throw new Error(`the list starts at ${real.top}px, the skeleton started at ${busy.top}px`);
    }
    return `row ${busy.row}px both ways, list top held at ${real.top}px (${busy.rows} reserved, ${real.rows} arrived)`;
  } finally {
    await session.send("Network.emulateNetworkConditions", fast).catch(() => {});
    await session.send("Network.disable").catch(() => {});
  }
}

/** ONE real interaction: click the Assigned to Me nav link like a person would. */
export async function checkNavClickToAssigned(ctx) {
  const { session } = ctx;

  const at = await clickElement(session, "#client-nav-assigned");
  const landed = await waitFor(
    session,
    `
    const heading = document.getElementById("route-heading");
    if (location.pathname !== "/app/assigned") return null;
    if (heading === null || heading.textContent.trim() !== "Assigned to Me") return null;
    return {
      path: location.pathname,
      focused: document.activeElement === null ? null : document.activeElement.id,
      current: document.getElementById("client-nav-assigned").getAttribute("aria-current"),
    };
  `,
    { timeoutMs: 5_000, what: "the Assigned to Me route" },
  );

  if (landed.focused !== "route-heading") {
    throw new Error(`focus went to "${landed.focused ?? "(none)"}", not the route heading`);
  }
  if (landed.current !== "page") throw new Error("the Assigned nav link is not aria-current=page");
  return `clicked at (${at.x},${at.y}) → ${landed.path}, focus on the heading`;
}

/**
 * Changing route must not move the frame either (item 4.6). The baseline here
 * is the Assigned route the previous check landed on; we go back to Initiatives
 * and the header, nav and main column must all be exactly where they were.
 */
export async function checkNoShiftAcrossRoutes(ctx) {
  const { session } = ctx;

  const before = await measureChrome(session);
  await clickElement(session, "#client-nav-initiatives");
  await waitFor(
    session,
    `
    const heading = document.getElementById("route-heading");
    if (location.pathname !== "/app/initiatives") return null;
    return heading !== null && heading.textContent.trim() === "My Initiatives";
  `,
    { timeoutMs: 5_000, what: "the Initiatives route" },
  );

  const moved = shifted(before, await measureChrome(session));
  if (moved.length > 0) throw new Error(`the frame moved on a route change: ${moved.join("; ")}`);
  return "header, nav and main column all held their place";
}

/**
 * Narrow viewport (item 4.1): the inline nav steps aside, one menu
 * control takes over, and it opens and closes the way a keyboard user expects —
 * Escape closes it and hands focus back to the trigger (UX_GUARDRAILS §3).
 * Opening it must not move the header (item 4.6).
 */
export async function checkNarrowMenu(ctx) {
  const { session } = ctx;

  await session.send("Emulation.setDeviceMetricsOverride", {
    ...NARROW_VIEWPORT,
    deviceScaleFactor: 1,
    mobile: false,
  });

  const collapsed = await waitFor(
    session,
    `
    const shown = (el) => el !== null && el.getBoundingClientRect().width > 0;
    const trigger = document.getElementById("client-menu-button");
    if (!shown(trigger)) return null;
    if (shown(document.getElementById("client-nav"))) return null;
    const r = trigger.getBoundingClientRect();
    return { w: Math.round(r.width), h: Math.round(r.height) };
  `,
    { timeoutMs: 5_000, what: "the nav to collapse behind the menu control" },
  );

  // UX_GUARDRAILS §5: the touch target is at least 44px on the short side.
  if (collapsed.h < 44) throw new Error(`the menu control is only ${collapsed.h}px tall`);

  const before = await measureChrome(session);
  await clickElement(session, "#client-menu-button");

  const opened = await waitFor(
    session,
    `
    const panel = document.getElementById("client-menu");
    const trigger = document.getElementById("client-menu-button");
    if (panel === null || panel.hasAttribute("hidden")) return null;
    if (trigger.getAttribute("aria-expanded") !== "true") return null;
    // Controls inside a CLOSED dialog are not menu items — they are not in the
    // menu, not focusable and not rendered. The menu's confirm lives inside the
    // panel on purpose (closing the panel must not unmount its form).
    const items = [...panel.querySelectorAll("a, button")].filter(
      (el) => el.closest("dialog:not([open])") === null,
    );
    const short = items.filter((el) => Math.round(el.getBoundingClientRect().height) < 44);
    // The account menu is gone below sm:, so its rows must be in here instead.
    const account = ["client-menu-account", "client-menu-preferences"].filter(
      (id) => !items.some((el) => el.id === id),
    );
    return { items: items.length, short: short.map((el) => el.id || el.textContent.trim()), account };
  `,
    { timeoutMs: 5_000, what: "the menu to open" },
  );

  if (opened.account.length > 0) {
    throw new Error(`the narrow menu has no account rows: #${opened.account.join(", #")}`);
  }
  if (opened.short.length > 0) {
    throw new Error(`menu items under the 44px touch target: ${opened.short.join(", ")}`);
  }
  const moved = shifted(before, await measureChrome(session));
  if (moved.length > 0) throw new Error(`opening the menu moved the frame: ${moved.join("; ")}`);

  await pressKey(session, "Escape", { windowsVirtualKeyCode: 27 });
  const closed = await waitFor(
    session,
    `
    const panel = document.getElementById("client-menu");
    if (panel === null || !panel.hasAttribute("hidden")) return null;
    const trigger = document.getElementById("client-menu-button");
    if (trigger.getAttribute("aria-expanded") !== "false") return null;
    return { focused: document.activeElement === null ? null : document.activeElement.id };
  `,
    { timeoutMs: 5_000, what: "Escape to close the menu" },
  );

  if (closed.focused !== "client-menu-button") {
    throw new Error(`focus went to "${closed.focused ?? "(none)"}", not back to the trigger`);
  }

  return `${opened.items} menu items, all >=44px; Escape closed it and returned focus`;
}

/**
 * The regression from fix round 1: Sign out in the narrow menu purged the local
 * cache, closed the menu (unmounting its form) and then "submitted" a form that
 * was no longer in the document — so the session never ended and the user was
 * told nothing.
 *
 * We do NOT sign the operator out: `form.submit` is replaced with a counter for
 * the duration of the check and restored afterwards. The purge itself is real,
 * so this tab's local snapshot cache for the signed-in account is emptied — it
 * is a disposable cache and refills from the server; no server data is touched.
 */
export async function checkMenuSignOutSubmits(ctx) {
  const { session } = ctx;

  await clickElement(session, "#client-menu-button");
  await waitFor(
    session,
    `
    const panel = document.getElementById("client-menu");
    return panel !== null && !panel.hasAttribute("hidden");
  `,
    { timeoutMs: 5_000, what: "the menu to reopen" },
  );

  const stubbed = await evaluate(
    session,
    `
    const form = document.getElementById("client-menu-sign-out-form");
    if (form === null) return { ok: false, why: "the menu has no sign-out form" };
    window.__doitSubmits = 0;
    form.submit = function () { window.__doitSubmits += 1; };
    return { ok: true };
  `,
  );
  if (!stubbed.ok) throw new Error(stubbed.why);

  try {
    await clickElement(session, "#client-menu-sign-out");
    const sent = await waitFor(
      session,
      `
      if (window.__doitSubmits !== 1) return null;
      const form = document.getElementById("client-menu-sign-out-form");
      return { mounted: form !== null, submits: window.__doitSubmits };
    `,
      { timeoutMs: 5_000, what: "the menu's Sign out to reach the form" },
    );

    if (!sent.mounted) {
      throw new Error("the sign-out form left the document before the request went");
    }
    return `Sign out submitted once, form still mounted (${sent.submits} submit)`;
  } finally {
    await evaluate(
      session,
      `
      const form = document.getElementById("client-menu-sign-out-form");
      if (form !== null) delete form.submit;
      delete window.__doitSubmits;
      return true;
    `,
    ).catch(() => {});
    await session.send("Emulation.setDeviceMetricsOverride", {
      ...VIEWPORT,
      deviceScaleFactor: 1,
      mobile: false,
    });
  }
}

/**
 * The connection summary (item 4.3, spec §7), driven for real: pull the network
 * out from under the tab and the badge must SAY so — in text, with an icon,
 * with its own `data-conn-state` — and must offer the way back. Then give the
 * network back: the badge stays offline until Retry is pressed, and pressing it
 * puts the tab back to live.
 *
 * It must also do all that without moving anything: the summary is positioned
 * out of flow precisely so six different states cannot resize the header
 * (item 4.6).
 */
export async function checkConnectionSummary(ctx) {
  const { session } = ctx;
  const fast = { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 };

  await session.send("Network.enable");
  try {
    const live = await waitFor(
      session,
      `
      const badge = document.getElementById("client-connection");
      if (badge === null) return null;
      if (badge.getAttribute("data-conn-state") !== "live") return null;
      const text = badge.querySelector("[data-conn-text]");
      const region = badge.querySelector('[role="status"]');
      return {
        region: region !== null,
        // The state is announced; the buttons must NOT be in the live region,
        // or every state change re-reads "Try again" at the user.
        buttonsInRegion:
          region === null ? true : region.querySelector("button") !== null,
        text: text === null ? "" : text.textContent.trim(),
      };
    `,
      { timeoutMs: READY_TIMEOUT_MS, what: "the connection summary to read live" },
    );

    if (!live.region) throw new Error("the summary announces nothing — no live region");
    if (live.buttonsInRegion) throw new Error("a control sits inside the summary's live region");
    if (live.text.length === 0) throw new Error("the live state has no text — colour alone");

    const before = await measureChrome(session);
    await session.send("Network.emulateNetworkConditions", { ...fast, offline: true });

    const dropped = await waitFor(
      session,
      `
      const badge = document.getElementById("client-connection");
      if (badge === null) return null;
      const state = badge.getAttribute("data-conn-state");
      if (state === "live") return null;
      const text = badge.querySelector("[data-conn-text]");
      const icon = badge.querySelector('[data-conn-badge] span[aria-hidden="true"]');
      return {
        state,
        text: text === null ? "" : text.textContent.trim(),
        icon: icon === null ? null : [...icon.classList].find((c) => c.startsWith("hero-")) ?? null,
        retry: document.getElementById("client-connection-retry") !== null,
      };
    `,
      // The browser fires `offline` the moment the tab loses its network, and
      // the client takes that signal: no waiting on a heartbeat to time out.
      { timeoutMs: 10_000, what: "the summary to notice the network went away" },
    );

    if (!dropped.state.startsWith("offline")) {
      throw new Error(`the tab is offline and the badge says "${dropped.state}"`);
    }
    if (dropped.text.length === 0) throw new Error(`state ${dropped.state} says nothing`);
    if (!/offline/i.test(dropped.text)) {
      throw new Error(`state ${dropped.state} reads "${dropped.text}" — not that we are offline`);
    }
    if (dropped.icon === null) throw new Error(`state ${dropped.state} has no icon`);
    if (!dropped.retry) {
      throw new Error("the client stopped retrying and offered no way to try again");
    }

    const moved = shifted(before, await measureChrome(session));
    if (moved.length > 0) throw new Error(`the summary moved the frame: ${moved.join("; ")}`);

    // Offline is the state where the summary MATTERS, and the state where it is
    // widest. So this is the moment to prove that at every desktop width the
    // band gets tight, Retry is still the thing under Retry — and the nav is
    // still the thing under the nav.
    const reachable = [];
    for (const width of CROWDED_WIDTHS) {
      await session.send("Emulation.setDeviceMetricsOverride", {
        width,
        height: VIEWPORT.height,
        deviceScaleFactor: 1,
        mobile: false,
      });

      const hit = await waitFor(
        session,
        `
        const covered = (id) => {
          const el = document.getElementById(id);
          if (el === null) return "missing";
          const r = el.getBoundingClientRect();
          if (r.width === 0 || r.height === 0) return "not shown";
          const at = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
          if (at === null) return "nothing";
          return el === at || el.contains(at) ? null : (at.id || at.tagName.toLowerCase());
        };
        const retry = covered("client-connection-retry");
        const nav = covered("client-nav-assigned");
        if (retry === "missing" || nav === "missing") return null;
        return { retry, nav };
      `,
        { timeoutMs: 5_000, what: `the header to settle at ${width}px` },
      );

      if (hit.retry !== null) {
        throw new Error(`at ${width}px, Try again is covered by ${hit.retry}`);
      }
      if (hit.nav !== null) {
        throw new Error(`at ${width}px, the Assigned nav button is covered by ${hit.nav}`);
      }
      reachable.push(width);
    }

    await session.send("Emulation.setDeviceMetricsOverride", {
      ...VIEWPORT,
      deviceScaleFactor: 1,
      mobile: false,
    });

    // The network comes back, and the badge stays offline until the user says
    // otherwise: one rule for the way back, and Retry is it.
    await session.send("Network.emulateNetworkConditions", fast);
    const stillOffline = await evaluate(
      session,
      `
      const badge = document.getElementById("client-connection");
      return badge === null ? null : badge.getAttribute("data-conn-state");
    `,
    );
    if (!String(stillOffline).startsWith("offline")) {
      throw new Error(`the badge left offline on its own (${stillOffline}) — Retry was never used`);
    }

    await clickElement(session, "#client-connection-retry");

    const back = await waitFor(
      session,
      `
      const badge = document.getElementById("client-connection");
      if (badge === null) return null;
      return badge.getAttribute("data-conn-state") === "live" ? true : null;
    `,
      { timeoutMs: 20_000, what: "the connection to come back" },
    );

    return `live → ${dropped.state} ("${dropped.text}", ${dropped.icon}) → live again (${back}); Try again and the nav both hit-testable at ${reachable.join(", ")}px`;
  } finally {
    await session.send("Network.emulateNetworkConditions", fast).catch(() => {});
    await session.send("Network.disable").catch(() => {});
    await session
      .send("Emulation.setDeviceMetricsOverride", {
        ...VIEWPORT,
        deviceScaleFactor: 1,
        mobile: false,
      })
      .catch(() => {});
  }
}

/**
 * The confirm dialog, opened for real (item 4.2, guardrails §3.1).
 *
 * The one confirm this client has is Sign out with work the server has not
 * acknowledged, so the check makes that true: it puts ONE queued op into this
 * tab's own local cache — the `pending_ops` store of the client's IndexedDB —
 * and reloads, which is exactly how a real tab learns it has unsent work.
 *
 * Then it drives the path a keyboard user drives: open the menu, press Sign
 * out, the dialog opens with focus INSIDE it, Escape closes it, and focus goes
 * back to the control that opened it.
 *
 * It answers CANCEL, never confirm — and `form.submit` is stubbed for the whole
 * check besides, so no path through it can end the operator's session. The
 * seeded row is deleted afterwards, and the tab reloaded, so the cache is left
 * as it was found.
 */
export async function checkDialogFocusReturn(ctx) {
  const { session } = ctx;

  // Fresh boot first: the check before this one signs out (with the request
  // stubbed), and a sign-out deletes this account's cache. The client opens it
  // again at boot, and there has to be a store here to put the op in.
  await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives` });
  await waitFor(session, "return window.__doit_client_ready === true;", {
    timeoutMs: READY_TIMEOUT_MS,
    what: "the client to come up before seeding",
  });
  await waitFor(
    session,
    `
    return (async () => {
      const dbs = await indexedDB.databases();
      const found = dbs.find((d) => /^doit:v\\d+:\\d+$/.test(d.name ?? ""));
      return found === undefined ? null : found.name;
    })();
  `,
    { timeoutMs: 10_000, what: "the client's local cache to open" },
  );

  try {
    // Seeded inside the try: once this has run, the cache carries a queued op
    // and cleanup (the `finally` below) must run whatever happens next —
    // including a throw from the seed itself — or the residue check fails and
    // the operator's next real tab inherits a fake pending write.
    const seed = await evaluate(
      session,
      `
      return (async () => {
      const dbs = await indexedDB.databases();
      const found = dbs.find((d) => /^doit:v\\d+:\\d+$/.test(d.name ?? ""));
      if (found === undefined) return { ok: false, why: "this tab has no client cache to seed" };
      const db = await new Promise((resolve, reject) => {
        // No version: open whatever is there. An upgrade here would be this
        // harness rewriting the operator's cache, which it has no business doing.
        const req = indexedDB.open(found.name);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
      if (!db.objectStoreNames.contains("pending_ops")) {
        db.close();
        return { ok: false, why: "the cache has no pending_ops store" };
      }
      await new Promise((resolve, reject) => {
        const tx = db.transaction("pending_ops", "readwrite");
        tx.objectStore("pending_ops").put({
          key: ${JSON.stringify("cdp-focus-return-check")},
          initiativeId: 0,
          createdAt: Date.now(),
          payload: { op: "harness_probe" },
        });
        tx.oncomplete = () => resolve(true);
        tx.onerror = () => reject(tx.error);
      });
      db.close();
      return { ok: true, db: found.name };
      })();
    `,
    );
    if (!seed.ok) throw new Error(seed.why);

    await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives` });
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come back up with the queued op",
    });

    await session.send("Emulation.setDeviceMetricsOverride", {
      ...NARROW_VIEWPORT,
      deviceScaleFactor: 1,
      mobile: false,
    });

    await waitFor(
      session,
      `
      const badge = document.getElementById("client-connection");
      return badge !== null && badge.getAttribute("data-conn-state") !== null ? true : null;
    `,
      { timeoutMs: 5_000, what: "the summary to mount" },
    );

    const stubbed = await evaluate(
      session,
      `
      const form = document.getElementById("client-menu-sign-out-form");
      if (form === null) return { ok: false, why: "the menu has no sign-out form" };
      window.__doitSubmits = 0;
      form.submit = function () { window.__doitSubmits += 1; };
      return { ok: true };
    `,
    );
    if (!stubbed.ok) throw new Error(stubbed.why);

    await clickElement(session, "#client-menu-button");
    await waitFor(
      session,
      `
      const panel = document.getElementById("client-menu");
      return panel !== null && !panel.hasAttribute("hidden") ? true : null;
    `,
      { timeoutMs: 5_000, what: "the menu to open" },
    );

    await clickElement(session, "#client-menu-sign-out");

    const opened = await waitFor(
      session,
      `
      const dialog = document.getElementById("client-menu-sign-out-confirm");
      if (dialog === null || !dialog.open) return null;
      const active = document.activeElement;
      const named = dialog.getAttribute("aria-labelledby");
      const described = dialog.getAttribute("aria-describedby");
      const title = named === null ? null : dialog.querySelector("#" + CSS.escape(named));
      const body = described === null ? null : dialog.querySelector("#" + CSS.escape(described));
      const buttons = [...dialog.querySelectorAll("button")].map((b) => b.textContent.trim());
      return {
        inside: dialog.contains(active),
        focused: active === null ? null : active.id || active.textContent.trim(),
        named: title !== null,
        described: body !== null,
        title: title === null ? "" : title.textContent.trim(),
        buttons,
        submits: window.__doitSubmits,
      };
    `,
      { timeoutMs: 5_000, what: "the confirm to open on unsent work" },
    );

    if (!opened.inside) throw new Error(`the dialog opened with focus on "${opened.focused}"`);
    if (!opened.named) throw new Error("aria-labelledby points at nothing inside the dialog");
    if (!opened.described) throw new Error("aria-describedby points at nothing inside the dialog");
    if (opened.buttons.length !== 2) throw new Error("a confirm has exactly two answers");
    if (opened.buttons.some((label) => label.length === 0)) {
      throw new Error("a confirm button with no words on it");
    }
    if (opened.submits !== 0) throw new Error("the form was submitted before the user answered");

    // A real Escape, virtual key code and all: the platform closes a modal
    // <dialog> itself, and it only does that for a key event the browser
    // recognises as Escape rather than one a JS handler merely reads.
    await pressKey(session, "Escape", { windowsVirtualKeyCode: 27 });

    const closed = await waitFor(
      session,
      `
      const dialog = document.getElementById("client-menu-sign-out-confirm");
      if (dialog === null || dialog.open) return null;
      const active = document.activeElement;
      return {
        focused: active === null ? null : active.id,
        submits: window.__doitSubmits,
      };
    `,
      { timeoutMs: 5_000, what: "Escape to close the confirm" },
    );

    if (closed.focused !== "client-menu-sign-out") {
      throw new Error(`focus went to "${closed.focused ?? "(none)"}", not back to the opener`);
    }
    if (closed.submits !== 0) throw new Error("Escape signed the user out");

    return `"${opened.title}" (${opened.buttons.join(" / ")}) opened with focus inside; Escape returned focus to Sign out`;
  } finally {
    await evaluate(
      session,
      `
      return (async () => {
      const form = document.getElementById("client-menu-sign-out-form");
      if (form !== null) delete form.submit;
      delete window.__doitSubmits;
      const dbs = await indexedDB.databases();
      const found = dbs.find((d) => /^doit:v\\d+:\\d+$/.test(d.name ?? ""));
      if (found === undefined) return true;
      const db = await new Promise((resolve, reject) => {
        const req = indexedDB.open(found.name);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
      if (db.objectStoreNames.contains("pending_ops")) {
        await new Promise((resolve) => {
          const tx = db.transaction("pending_ops", "readwrite");
          tx.objectStore("pending_ops").delete(${JSON.stringify("cdp-focus-return-check")});
          tx.oncomplete = () => resolve(true);
          tx.onerror = () => resolve(true);
        });
      }
      db.close();
      return true;
      })();
    `,
    ).catch(() => {});

    await session.send("Emulation.setDeviceMetricsOverride", {
      ...VIEWPORT,
      deviceScaleFactor: 1,
      mobile: false,
    });
    // Back to a tab with nothing queued: the seeded op is gone from the device,
    // and this drops it from the running client too.
    await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives` }).catch(() => {});
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come back up with a clean cache",
    }).catch(() => {});
  }
}

/**
 * The theme, driven both ways in a real browser (items 2.5, 4.2, 4.7 — audit 6.3).
 *
 * The control is the product's three-way System / Light / Dark group: three
 * segments, the one in force pressed in. Pressing one is a local action — the
 * pressed segment, the `data-theme` attribute and the saved preference all move
 * on the click, with nothing in between (§6.7) — and it must not move the frame
 * a pixel (item 4.4). Then the preference is reloaded, because a theme that
 * does not survive a refresh is a theme the user has to set again every morning.
 *
 * The preference lives in the operator's own profile, so whatever was there
 * when we arrived is put back before we leave.
 */
export async function checkThemeBothWays(ctx) {
  const { session } = ctx;

  const before = await evaluate(
    session,
    `return { saved: localStorage.getItem("phx:theme") };`,
  );

  try {
    const group = await evaluate(
      session,
      `
      const g = document.getElementById("client-theme-toggle");
      if (g === null) return { missing: true };
      const segments = [...g.querySelectorAll("[data-theme-choice]")];
      const short = segments.filter((el) => {
        const r = el.getBoundingClientRect();
        return Math.round(r.height) < 44 && window.innerWidth < 640;
      });
      return {
        missing: false,
        role: g.getAttribute("role"),
        name: g.getAttribute("aria-label"),
        choices: segments.map((el) => el.dataset.themeChoice),
        named: segments.every((el) => (el.getAttribute("aria-label") ?? "").trim().length > 0),
        short: short.length,
      };
    `,
    );

    if (group.missing) throw new Error("no theme control in the header");
    if (group.role !== "group") throw new Error(`the theme control is role="${group.role}"`);
    if (group.choices.join(",") !== "system,light,dark") {
      throw new Error(`the theme group offers ${group.choices.join(", ") || "nothing"}`);
    }
    if (!group.named) throw new Error("a theme segment has no accessible name");
    if (group.short > 0) throw new Error(`${group.short} theme segment(s) under 44px`);

    // Pressing a segment must not resize the group or move anything around it.
    const framed = await measureChrome(session);
    await clickElement(session, "#client-theme-toggle-light");
    const light = await waitFor(session, themeStateJs, {
      timeoutMs: 5_000,
      what: "the theme to go light",
    });
    const moved = shifted(framed, await measureChrome(session));
    if (moved.length > 0) throw new Error(`pressing a theme segment moved the frame: ${moved.join("; ")}`);

    if (light.pressed !== "light") throw new Error(`Light is not the pressed segment (${light.pressed})`);
    if (light.attr !== "light") throw new Error(`Light is pressed, <html> says ${light.attr}`);
    if (light.saved !== "light") throw new Error(`Light was not saved (${light.saved})`);

    await clickElement(session, "#client-theme-toggle-dark");
    const dark = await waitFor(
      session,
      `
      const root = document.documentElement;
      if (root.getAttribute("data-theme") !== "dark") return null;
      const on = document.querySelector('[data-theme-choice][aria-pressed="true"]');
      if (on === null || on.dataset.themeChoice !== "dark") return null;
      return {
        pressed: "dark",
        attr: "dark",
        saved: localStorage.getItem("phx:theme"),
        headerBg: getComputedStyle(document.getElementById("client-header")).backgroundColor,
        name: on.getAttribute("aria-label"),
      };
    `,
      { timeoutMs: 5_000, what: "the theme to go dark" },
    );

    if (dark.saved !== "dark") throw new Error(`Dark was not saved (${dark.saved})`);
    if (dark.headerBg === light.headerBg) {
      throw new Error(`the header is ${dark.headerBg} in both themes — the control lied`);
    }
    if (!/dark/i.test(dark.name ?? "")) {
      throw new Error(`the pressed segment is named "${dark.name}" — it does not say which theme it sets`);
    }

    // Dark survives a refresh, and it is on the document from the first paint:
    // the sample is taken the moment <html> exists, and it already carries the
    // attribute whether or not the client has said it is ready.
    await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives` });
    const firstPaint = await waitFor(
      session,
      `
      const root = document.documentElement;
      const attr = root.getAttribute("data-theme");
      if (attr === null) return null;
      return { attr, ready: window.__doit_client_ready === true };
    `,
      { timeoutMs: READY_TIMEOUT_MS, everyMs: 5, what: "<html> to carry a theme" },
    );
    if (firstPaint.attr !== "dark") {
      throw new Error(`a refresh painted ${firstPaint.attr}, not the saved dark`);
    }

    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come back up",
    });
    const afterReload = await waitFor(session, themeStateJs, {
      timeoutMs: 5_000,
      what: "the theme group to come back",
    });
    if (afterReload.pressed !== "dark") {
      throw new Error(`"${afterReload.pressed}" is pressed after a refresh, not dark`);
    }

    // And back to System: the preference is stored as ABSENCE, and the document
    // still carries an explicit light/dark resolved against the OS.
    await clickElement(session, "#client-theme-toggle-system");
    const system = await waitFor(
      session,
      `
      const on = document.querySelector('[data-theme-choice][aria-pressed="true"]');
      if (on === null || on.dataset.themeChoice !== "system") return null;
      return {
        saved: localStorage.getItem("phx:theme"),
        attr: document.documentElement.getAttribute("data-theme"),
        prefersDark: window.matchMedia("(prefers-color-scheme: dark)").matches,
      };
    `,
      { timeoutMs: 5_000, what: "the theme to go back to System" },
    );
    if (system.saved !== null) throw new Error(`System was saved as "${system.saved}"`);
    const resolved = system.prefersDark ? "dark" : "light";
    if (system.attr !== resolved) {
      throw new Error(`System resolved to ${system.attr}, but the OS asks for ${resolved}`);
    }

    return `three segments; Light \u2192 Dark (${dark.headerBg} vs ${light.headerBg}) with no shift, dark held across a refresh${
      firstPaint.ready ? "" : " before the client was ready"
    }, System resolved to ${resolved}`;
  } finally {
    await evaluate(
      session,
      before.saved === null
        ? `localStorage.removeItem("phx:theme"); return true;`
        : `localStorage.setItem("phx:theme", ${JSON.stringify(before.saved)}); return true;`,
    ).catch(() => {});
    await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives` }).catch(() => {});
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come back on the operator's theme",
    }).catch(() => {});
  }
}

/** Which segment is pressed, and what the document and the profile say. */
const themeStateJs = `
  const on = document.querySelector('[data-theme-choice][aria-pressed="true"]');
  if (on === null) return null;
  return {
    pressed: on.dataset.themeChoice,
    attr: document.documentElement.getAttribute("data-theme"),
    saved: localStorage.getItem("phx:theme"),
    headerBg: getComputedStyle(document.getElementById("client-header")).backgroundColor,
    name: on.getAttribute("aria-label"),
  };
`;

/**
 * The frame by keyboard alone (audit 6.4, guardrails §3).
 *
 * Tab from the top of the document and the frame has to hand itself over in
 * reading order — the skip link first, then the wordmark, then the nav — and
 * every stop has to be a control you can see and name. Then the skip link is
 * used for what it is for: one press and the caret is in `<main>`.
 */
export async function checkKeyboardTraversal(ctx) {
  const { session } = ctx;

  // A fresh document, not just a blur: blurring leaves the browser's sequential
  // focus starting point wherever the last check left it, so the first Tab
  // would carry on from the middle of the header instead of the top.
  await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives` });
  await waitFor(session, "return window.__doit_client_ready === true;", {
    timeoutMs: READY_TIMEOUT_MS,
    what: "the client to come up before tabbing through it",
  });
  await evaluate(session, `window.scrollTo(0, 0); return true;`);

  const expected = [
    "client-skip-link",
    "client-wordmark",
    "client-nav-initiatives",
    "client-nav-assigned",
    "client-theme-toggle-system",
    "client-theme-toggle-light",
    "client-theme-toggle-dark",
    "client-touch-switch",
    "client-bell-button",
    "client-account-menu-button",
  ];

  const seen = [];
  for (let i = 0; i < expected.length; i += 1) {
    await pressKey(session, "Tab", { windowsVirtualKeyCode: 9 });
    const stop = await evaluate(
      session,
      `
      const el = document.activeElement;
      if (el === null || el === document.body) return null;
      const r = el.getBoundingClientRect();
      const style = getComputedStyle(el);
      return {
        id: el.id,
        name: (el.getAttribute("aria-label") ?? el.textContent ?? "").trim(),
        visible: r.width > 0 && r.height > 0 && style.visibility !== "hidden",
      };
    `,
    );
    if (stop === null) throw new Error(`Tab ${i + 1} left focus on nothing (body)`);
    seen.push(stop);
  }

  const order = seen.map((s) => s.id);
  if (order.join(",") !== expected.join(",")) {
    throw new Error(`tab order is ${order.join(" → ")}, expected ${expected.join(" → ")}`);
  }
  const nameless = seen.filter((s) => s.name.length === 0);
  if (nameless.length > 0) {
    throw new Error(`a focus stop with no accessible name: #${nameless.map((s) => s.id).join(", #")}`);
  }
  const invisible = seen.filter((s) => !s.visible);
  if (invisible.length > 0) {
    throw new Error(`focus went somewhere invisible: #${invisible.map((s) => s.id).join(", #")}`);
  }

  // The skip link, used: focus it again and press it.
  await evaluate(session, `document.getElementById("client-skip-link").focus(); return true;`);
  await pressKey(session, "Enter", { windowsVirtualKeyCode: 13 });
  const skipped = await waitFor(
    session,
    `
    const main = document.getElementById("client-main");
    const active = document.activeElement;
    if (main === null) return null;
    if (active !== main && !main.contains(active)) return null;
    return { id: active === null ? null : active.id, hash: location.hash };
  `,
    { timeoutMs: 5_000, what: "the skip link to put focus in the main column" },
  );

  return `${order.length} stops in order, all named; skip link landed on #${skipped.id || "(inside main)"}`;
}

/**
 * Reduced motion, asked for the way a real user asks for it (audit 6.4,
 * guardrails §1.2) — the OS preference, emulated, not a class name read off a
 * string in a unit test.
 */
export async function checkReducedMotion(ctx) {
  const { session } = ctx;
  const fast = { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 };

  const motion = async () =>
    evaluate(
      session,
      `
      const el = document.getElementById("client-nav-initiatives");
      if (el === null) return null;
      const s = getComputedStyle(el);
      return {
        duration: s.transitionDuration,
        property: s.transitionProperty,
        reduced: window.matchMedia("(prefers-reduced-motion: reduce)").matches,
      };
    `,
    );

  // `transition-none` turns the transition off by taking away the PROPERTY, so
  // that is what has to change; a duration left on a transition of nothing
  // animates nothing.
  const off = (m) => m.property === "none" || parseFloat(m.duration) === 0;

  await session.send("Emulation.setEmulatedMedia", {
    features: [{ name: "prefers-reduced-motion", value: "no-preference" }],
  });
  const moving = await motion();
  if (moving === null) throw new Error("no nav control to measure");
  if (off(moving)) {
    throw new Error("the nav control has no transition to guard in the first place");
  }

  await session.send("Network.enable");
  try {
    await session.send("Emulation.setEmulatedMedia", {
      features: [{ name: "prefers-reduced-motion", value: "reduce" }],
    });
    const still = await motion();
    if (!still.reduced) throw new Error("the page does not see the reduced-motion preference");
    if (!off(still)) {
      throw new Error(
        `transitions still run under reduced motion (${still.property} for ${still.duration})`,
      );
    }

    // The loading skeleton is the one thing that animates on its own, so it is
    // the one that has to stop. It is short-lived, so the read is slowed to
    // make it observable.
    await session.send("Network.emulateNetworkConditions", { ...fast, latency: 1200 });
    await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives` });
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come up on a slow link",
    });

    const skeleton = await waitFor(
      session,
      `
      const row = document.querySelector('#initiatives-skeleton div[aria-hidden="true"]');
      if (row === null) return null;
      const s = getComputedStyle(row);
      return { animation: s.animationName, iteration: s.animationIterationCount };
    `,
      { timeoutMs: READY_TIMEOUT_MS, what: "the loading skeleton" },
    );

    if (skeleton.animation !== "none") {
      throw new Error(`the skeleton still pulses (${skeleton.animation}) under reduced motion`);
    }

    return `transition-property ${moving.property} (${moving.duration}) → ${still.property}, skeleton animation ${skeleton.animation}`;
  } finally {
    await session.send("Network.emulateNetworkConditions", fast).catch(() => {});
    await session.send("Network.disable").catch(() => {});
    await session.send("Emulation.setEmulatedMedia", { features: [] }).catch(() => {});
    await waitFor(
      session,
      `return document.querySelector("#initiatives > [data-initiative-id]") !== null ? true : null;`,
      { timeoutMs: READY_TIMEOUT_MS, what: "the rows to land" },
    ).catch(() => {});
  }
}

/**
 * A deep link, then the browser's own back and forward (audit 6.2).
 *
 * `/app/account` typed straight into the address bar has to resolve to the
 * Account screen — the document is the same for every path, so the client is
 * the one doing the resolving. Then back and forward have to return the user to
 * where they were, scroll position included, because a list you have to scroll
 * again is a list you have lost your place in.
 */
export async function checkDeepLinkAndHistory(ctx) {
  const { session } = ctx;

  await session.send("Page.navigate", { url: `${ctx.appUrl}/app/account` });
  await waitFor(session, "return window.__doit_client_ready === true;", {
    timeoutMs: READY_TIMEOUT_MS,
    what: "the client to come up on a deep link",
  });

  const deep = await waitFor(
    session,
    `
    const heading = document.getElementById("route-heading");
    if (heading === null || heading.textContent.trim() !== "Account") return null;
    // Account lives behind the avatar menu, so no nav entry may claim it.
    const claimed = ["initiatives", "assigned"].filter((k) =>
      document.getElementById("client-nav-" + k)?.getAttribute("aria-current") === "page");
    return { path: location.pathname, current: claimed.length === 0 ? "none" : claimed.join(",") };
  `,
    { timeoutMs: READY_TIMEOUT_MS, what: "the Account screen on a direct load" },
  );
  if (deep.path !== "/app/account") throw new Error(`landed on ${deep.path}`);
  if (deep.current !== "none") throw new Error(`a nav entry claims the Account route: ${deep.current}`);

  // To the list, scrolled down, then away again.
  await clickElement(session, "#client-nav-initiatives");
  const scrolled = await waitFor(
    session,
    `
    const scroller = document.getElementById("client-scroll");
    if (scroller === null) return null;
    if (document.querySelector("#initiatives > [data-initiative-id]") === null) return null;
    const room = scroller.scrollHeight - scroller.clientHeight;
    if (room <= 0) return { top: 0, room: 0 };
    const top = Math.min(240, room);
    scroller.scrollTop = top;
    return { top: Math.round(scroller.scrollTop), room: Math.round(room) };
  `,
    { timeoutMs: READY_TIMEOUT_MS, what: "the Initiatives list to scroll" },
  );

  await clickElement(session, "#client-nav-assigned");
  await waitFor(
    session,
    `
    const heading = document.getElementById("route-heading");
    return heading !== null && heading.textContent.trim() === "Assigned to Me" ? true : null;
  `,
    { timeoutMs: 5_000, what: "the Assigned to Me route" },
  );

  await evaluate(session, `history.back(); return true;`);
  const back = await waitFor(
    session,
    `
    const heading = document.getElementById("route-heading");
    if (location.pathname !== "/app/initiatives") return null;
    if (heading === null || heading.textContent.trim() !== "My Initiatives") return null;
    const scroller = document.getElementById("client-scroll");
    if (document.querySelector("#initiatives > [data-initiative-id]") === null) return null;
    return { top: Math.round(scroller.scrollTop) };
  `,
    { timeoutMs: 10_000, what: "back to the Initiatives list" },
  );

  if (scrolled.top > 0) {
    const restored = await waitFor(
      session,
      `
      const scroller = document.getElementById("client-scroll");
      return Math.abs(scroller.scrollTop - ${scrolled.top}) <= 2 ? Math.round(scroller.scrollTop) : null;
    `,
      { timeoutMs: 10_000, what: "the remembered scroll position" },
    ).catch(() => {
      throw new Error(`back restored scroll to ${back.top}px, not the ${scrolled.top}px left behind`);
    });
    if (restored === null) throw new Error("scroll was not restored");
  }

  await evaluate(session, `history.forward(); return true;`);
  const forward = await waitFor(
    session,
    `
    const heading = document.getElementById("route-heading");
    if (location.pathname !== "/app/assigned") return null;
    return heading !== null && heading.textContent.trim() === "Assigned to Me" ? true : null;
  `,
    { timeoutMs: 10_000, what: "forward to Assigned to Me" },
  );

  return `deep link → Account, back restored ${scrolled.top}px of scroll${
    scrolled.room === 0 ? " (list fits, nothing to restore)" : ""
  }, forward returned (${forward})`;
}

/**
 * §6 under latency (audit 6.5). A slow server must not slow the ANSWER: the
 * press is acknowledged on the spot and the wait is shown as a wait.
 *
 * Measured in the page, between the click landing and the new route being on
 * the glass, with two seconds of latency on every request.
 */
export async function checkAckUnderLatency(ctx) {
  const { session } = ctx;
  const fast = { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 };
  const BUDGET_MS = 100;

  await session.send("Network.enable");
  try {
    await session.send("Page.navigate", { url: `${ctx.appUrl}/app/account` });
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come up",
    });

    await session.send("Network.emulateNetworkConditions", { ...fast, latency: 2000 });

    // The stopwatch lives in the page: t0 on the click itself (capture, so it
    // is stamped before any handler runs), t1 on the first frame that shows
    // the new route.
    await evaluate(
      session,
      `
      window.__ack = { t0: null, route: null, busy: null };
      document.addEventListener("click", () => { window.__ack.t0 = performance.now(); }, { capture: true, once: true });
      const tick = () => {
        const a = window.__ack;
        if (a.t0 !== null) {
          const heading = document.getElementById("route-heading");
          const showing = location.pathname === "/app/initiatives" &&
            heading !== null && heading.textContent.trim() === "My Initiatives";
          if (showing && a.route === null) a.route = performance.now();
          const skeleton = document.getElementById("initiatives-skeleton");
          if (a.busy === null && skeleton !== null && skeleton.getAttribute("aria-busy") === "true") {
            a.busy = performance.now();
          }
        }
        if (a.route === null || a.busy === null) requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      return true;
    `,
    );

    await clickElement(session, "#client-nav-initiatives");

    const ack = await waitFor(
      session,
      `
      const a = window.__ack;
      if (a === undefined || a.t0 === null || a.route === null) return null;
      return {
        routeMs: Math.round(a.route - a.t0),
        busyMs: a.busy === null ? null : Math.round(a.busy - a.t0),
        stillBusy: document.getElementById("initiatives-skeleton") !== null,
      };
    `,
      { timeoutMs: 10_000, what: "the route to appear" },
    );

    if (ack.routeMs > BUDGET_MS) {
      throw new Error(`the route took ${ack.routeMs}ms to acknowledge a click on a 2s link`);
    }
    if (ack.busyMs === null) {
      throw new Error("the wait was never shown — no in-flight signifier while the read ran");
    }
    if (ack.busyMs > BUDGET_MS) {
      throw new Error(`the in-flight signifier took ${ack.busyMs}ms to appear`);
    }

    // The theme toggle is entirely local: it must not know the link is slow.
    // Timed in the page, the same way — a stopwatch run over CDP would be
    // measuring this harness's round trips, not the client.
    const theme = await evaluate(
      session,
      `
      const on = document.querySelector('[data-theme-choice][aria-pressed="true"]');
      if (on === null) return null;
      const was = on.dataset.themeChoice;
      const other = [...document.querySelectorAll("#client-theme-toggle [data-theme-choice]")]
        .map((el) => el.dataset.themeChoice)
        .find((choice) => choice !== was);
      window.__theme = { t0: null, at: null, was, other };
      document.addEventListener("click", () => { window.__theme.t0 = performance.now(); }, { capture: true, once: true });
      const tick = () => {
        const t = window.__theme;
        const now = document.querySelector('[data-theme-choice][aria-pressed="true"]');
        if (t.t0 !== null && t.at === null && now !== null && now.dataset.themeChoice !== t.was) {
          t.at = performance.now();
          return;
        }
        requestAnimationFrame(tick);
      };
      requestAnimationFrame(tick);
      return { was, other };
    `,
    );
    if (theme === null) throw new Error("no theme segment is pressed");

    await clickElement(session, `#client-theme-toggle-${theme.other}`);
    const themeMs = await waitFor(
      session,
      `
      const t = window.__theme;
      if (t === undefined || t.t0 === null || t.at === null) return null;
      return Math.round(t.at - t.t0);
    `,
      { timeoutMs: 5_000, everyMs: 10, what: "the theme to flip on a slow link" },
    );
    if (themeMs > BUDGET_MS) {
      throw new Error(`the theme toggle took ${themeMs}ms on a 2s link — nothing about it is remote`);
    }
    // Put the operator's theme back the way the toggle found it.
    await clickElement(session, `#client-theme-toggle-${theme.was}`).catch(() => {});

    await session.send("Network.emulateNetworkConditions", fast);
    return `route on the glass in ${ack.routeMs}ms and the wait shown in ${ack.busyMs}ms on a 2s link; theme flipped in ${themeMs}ms`;
  } finally {
    await session.send("Network.emulateNetworkConditions", fast).catch(() => {});
    await session.send("Network.disable").catch(() => {});
    await evaluate(session, `delete window.__ack; delete window.__theme; return true;`).catch(
      () => {},
    );
  }
}

/**
 * Disconnected startup (audit 6.5, guardrails §6.8, spec §7).
 *
 * The client boots with its data surface and its socket unreachable: the frame
 * still paints, its controls still work, the screen says so in place with a way
 * to try again, and — once the machine itself reports no network — the
 * connection summary says offline and offers Retry.
 *
 * The document and the bundle are allowed through, because a browser with no
 * network at all never gets as far as running this client; everything the
 * client would talk to afterwards is blocked.
 */
export async function checkDisconnectedStartup(ctx) {
  const { session } = ctx;
  const fast = { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 };

  await session.send("Network.enable");
  try {
    await session.send("Network.setBlockedURLs", {
      urls: ["*/app/api/*", "*/socket/*", "*/socket"],
    });
    await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives` });
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come up with nothing to talk to",
    });

    const painted = await waitFor(
      session,
      `
      const ids = ["client-header", "client-nav-initiatives", "client-main",
                   "client-theme-toggle", "client-bell-button", "client-account-menu-button",
                   "client-connection"];
      const missing = ids.filter((id) => document.getElementById(id) === null);
      if (missing.length > 0) return null;
      const error = document.getElementById("screen-error");
      if (error === null) return null;
      const retry = [...error.querySelectorAll("button")].map((b) => b.textContent.trim());
      return {
        retry,
        conn: document.getElementById("client-connection").getAttribute("data-conn-state"),
      };
    `,
      { timeoutMs: READY_TIMEOUT_MS, what: "the frame and the in-place read failure" },
    );

    if (painted.retry.length === 0) {
      throw new Error("the read failed and the screen offered no way to try again");
    }

    // The controls respond with no network behind them: a route change is
    // entirely local, and it must be instant.
    await clickElement(session, "#client-nav-assigned");
    await waitFor(
      session,
      `
      const heading = document.getElementById("route-heading");
      return location.pathname === "/app/assigned" && heading !== null &&
        heading.textContent.trim() === "Assigned to Me" ? true : null;
    `,
      { timeoutMs: 5_000, what: "a route change with no network" },
    );

    // What the summary said while only the SERVER was unreachable — the machine
    // still claims to have a network here. Recorded, not asserted: see the
    // matrix's known gap on connect-time online checks.
    const beforeOffline = await evaluate(
      session,
      `
      const badge = document.getElementById("client-connection");
      return badge === null ? null : badge.getAttribute("data-conn-state");
    `,
    );

    await session.send("Network.emulateNetworkConditions", { ...fast, offline: true });
    const offline = await waitFor(
      session,
      `
      const badge = document.getElementById("client-connection");
      if (badge === null) return null;
      const state = badge.getAttribute("data-conn-state");
      if (!String(state).startsWith("offline")) return null;
      const text = badge.querySelector("[data-conn-text]");
      return {
        state,
        text: text === null ? "" : text.textContent.trim(),
        retry: document.getElementById("client-connection-retry") !== null,
      };
    `,
      { timeoutMs: 15_000, what: "the summary to say we are offline" },
    );

    if (!offline.retry) throw new Error("offline, and no Retry to get back");
    if (!/offline/i.test(offline.text)) {
      throw new Error(`the summary reads "${offline.text}" with no network`);
    }

    return `frame painted, route changed, read failed in place with "${painted.retry.join(
      " / ",
    )}"; summary ${beforeOffline} → ${offline.state} ("${offline.text}") with Retry`;
  } finally {
    await session.send("Network.setBlockedURLs", { urls: [] }).catch(() => {});
    await session.send("Network.emulateNetworkConditions", fast).catch(() => {});
    await session.send("Network.disable").catch(() => {});
    await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives` }).catch(() => {});
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come back with its network",
    }).catch(() => {});
    // The give-up state does not heal itself — Retry is the way back, and the
    // next check expects a live tab.
    await evaluate(
      session,
      `
      const retry = document.getElementById("client-connection-retry");
      if (retry !== null) retry.click();
      return true;
    `,
    ).catch(() => {});
  }
}

/**
 * Nothing this harness did is still on the operator's device.
 *
 * The dialog check seeds one queued op into this profile's client cache to make
 * the confirm real. It deletes it again — and this is the check that says so
 * out loud, because a phantom pending write would tell the operator their work
 * never reached the server.
 */
export async function checkNoHarnessResidue(ctx) {
  const { session } = ctx;

  const residue = await evaluate(
    session,
    `
    return (async () => {
      if (typeof indexedDB.databases !== "function") return { skipped: true };
      const dbs = await indexedDB.databases();
      const found = dbs.find((d) => /^doit:v\\d+:\\d+$/.test(d.name ?? ""));
      if (found === undefined) return { skipped: true };
      const db = await new Promise((resolve, reject) => {
        const req = indexedDB.open(found.name);
        req.onsuccess = () => resolve(req.result);
        req.onerror = () => reject(req.error);
      });
      if (!db.objectStoreNames.contains("pending_ops")) {
        db.close();
        return { skipped: true };
      }
      const keys = await new Promise((resolve, reject) => {
        const req = db.transaction("pending_ops", "readonly").objectStore("pending_ops").getAllKeys();
        req.onsuccess = () => resolve(req.result ?? []);
        req.onerror = () => reject(req.error);
      });
      db.close();
      return { skipped: false, db: found.name, keys: keys.map(String) };
    })();
  `,
  );

  if (residue.skipped) return "no client cache in this profile to check";
  const ours = residue.keys.filter((key) => key.startsWith("cdp-"));
  if (ours.length > 0) {
    throw new Error(`the harness left queued writes behind: ${ours.join(", ")}`);
  }
  if (residue.keys.length > 0) {
    return `${residue.keys.length} queued write(s) in ${residue.db}, none of them ours`;
  }
  return `pending_ops is empty in ${residue.db}`;
}

/**
 * The notifications bell (item 4.6.3).
 *
 * It is a top-level item next to the account menu, it opens locally, the unread
 * dot lives inside its own box so nothing moves when it appears, and Escape
 * closes it and gives focus back.
 *
 * The operator's real notifications are NOT marked read: the write is
 * intercepted for the duration of the check and the payload asserted instead of
 * sent. Nothing reaches the server.
 */
export async function checkBell(ctx) {
  const { session } = ctx;

  // What the SERVER says this user has, read before anything is stubbed. The
  // bell loads asynchronously, so without this the check races the read and
  // reports whatever happened to be on screen — "0 rows" one run, ten the next.
  const server = await evaluate(
    session,
    `
    return (async () => {
      const response = await fetch("/app/api/notifications", {
        headers: { accept: "application/json" },
        credentials: "same-origin",
      });
      if (!response.ok) return { ok: false, why: "the notifications read answered " + response.status };
      const body = await response.json();
      const data = body && body.data ? body.data : {};
      return { ok: true, rows: (data.recent || []).length, unread: data.unread || 0 };
    })();
  `,
  );
  if (!server.ok) throw new Error(server.why);

  const stubbed = await evaluate(
    session,
    `
    if (document.getElementById("client-bell-button") === null) {
      return { ok: false, why: "there is no bell in the header" };
    }
    window.__doitOps = [];
    window.__doitRealFetch = window.fetch;
    window.fetch = function (input, init) {
      const url = String(input && input.url ? input.url : input);
      if (url.includes("/app/api/operations")) {
        window.__doitOps.push(String((init && init.body) || ""));
        return Promise.resolve(
          new Response(JSON.stringify({ data: { results: [] } }), {
            status: 200,
            headers: { "content-type": "application/json" },
          }),
        );
      }
      return window.__doitRealFetch.call(window, input, init);
    };
    const dot = document.querySelector("#client-bell-button [data-notif-dot]");
    return { ok: true, unreadBefore: dot !== null };
  `,
  );
  if (!stubbed.ok) throw new Error(stubbed.why);

  try {
    const before = await measureChrome(session);
    await clickElement(session, "#client-bell-button");

    const opened = await waitFor(
      session,
      `
      const panel = document.getElementById("client-bell-list");
      const trigger = document.getElementById("client-bell-button");
      if (panel === null || panel.hasAttribute("hidden")) return null;
      if (trigger.getAttribute("aria-expanded") !== "true") return null;
      const items = [...panel.querySelectorAll('[role="menuitem"]')];
      // The bell must be showing what the server has, not a half-loaded list.
      // Opening clears the unread count optimistically, so the "Mark all read"
      // item is gone by the time we look: the rows are all that is left.
      if (items.length !== ${server.rows}) return null;
      return {
        items: items.length,
        short: items.filter((el) => Math.round(el.getBoundingClientRect().height) < 36).length,
        named: items.every((el) => el.textContent.trim().length > 0),
        dot: document.querySelector("#client-bell-button [data-notif-dot]") !== null,
        role: panel.getAttribute("role"),
        name: trigger.getAttribute("aria-label"),
      };
    `,
      { timeoutMs: 10_000, what: `the bell to open with its ${server.rows} row(s)` },
    );

    if (opened.role !== "menu") throw new Error(`the flyout is role="${opened.role}"`);
    if (!/notification/i.test(opened.name ?? "")) {
      throw new Error(`the bell is named "${opened.name}" \u2014 it does not say what it is`);
    }
    if (!opened.named) throw new Error("a notification row has no words");
    if (opened.short > 0) throw new Error(`${opened.short} flyout row(s) under 36px`);

    const moved = shifted(before, await measureChrome(session));
    if (moved.length > 0) throw new Error(`opening the bell moved the frame: ${moved.join("; ")}`);

    // Opening acknowledges instantly: the dot is gone before the write lands
    // (it never lands here \u2014 we are holding it).
    const ops = await evaluate(session, `return window.__doitOps.slice();`);
    if (stubbed.unreadBefore) {
      if (opened.dot) throw new Error("the dot is still showing after the bell was opened");
      if (ops.length !== 1) throw new Error(`${ops.length} write(s) went out, expected 1`);
      const sent = JSON.stringify(JSON.parse(ops[0]));
      const expected = JSON.stringify(markAllReadRequest());
      if (sent !== expected) {
        throw new Error(`mark-read sent ${sent}, not ${expected}`);
      }
    } else if (ops.length > 0) {
      throw new Error("the bell wrote to the server with nothing unread");
    }

    await pressKey(session, "Escape", { windowsVirtualKeyCode: 27 });
    const closed = await waitFor(
      session,
      `
      const panel = document.getElementById("client-bell-list");
      if (panel === null || !panel.hasAttribute("hidden")) return null;
      if (document.getElementById("client-bell-button").getAttribute("aria-expanded") !== "false") {
        return null;
      }
      return { focused: document.activeElement === null ? null : document.activeElement.id };
    `,
      { timeoutMs: 5_000, what: "Escape to close the bell" },
    );
    if (closed.focused !== "client-bell-button") {
      throw new Error(`focus went to "${closed.focused ?? "(none)"}", not back to the bell`);
    }

    return `${opened.items} row(s), ${
      stubbed.unreadBefore ? "opening cleared the dot and sent the existing operation" : "nothing unread"
    }, Escape closed it and returned focus`;
  } finally {
    await evaluate(
      session,
      `
      if (typeof window.__doitRealFetch === "function") window.fetch = window.__doitRealFetch;
      delete window.__doitRealFetch;
      delete window.__doitOps;
      return true;
    `,
    ).catch(() => {});
  }
}

/**
 * The account menu (item 4.5): the avatar in the top right, and behind it the
 * three things the LiveView header has behind it. Opening is local, Escape
 * closes it and hands focus back.
 *
 * Sign out is NOT pressed here \u2014 the narrow menu's check already proves the
 * flow reaches the form, with the submit stubbed.
 */
export async function checkAccountMenu(ctx) {
  const { session } = ctx;

  const before = await measureChrome(session);
  await clickElement(session, "#client-account-menu-button");

  const opened = await waitFor(
    session,
    `
    const panel = document.getElementById("client-account-menu-list");
    const trigger = document.getElementById("client-account-menu-button");
    if (panel === null || panel.hasAttribute("hidden")) return null;
    if (trigger.getAttribute("aria-expanded") !== "true") return null;
    const items = [...panel.querySelectorAll('[role="menuitem"]')];
    return {
      ids: items.map((el) => el.id),
      labels: items.map((el) => el.textContent.trim()),
      short: items.filter((el) => Math.round(el.getBoundingClientRect().height) < 36).length,
      avatar: trigger.querySelector("[data-avatar]") !== null,
      initials: (trigger.querySelector("[data-avatar]")?.textContent ?? "").trim(),
      name: trigger.textContent.trim(),
      form: document.getElementById("client-account-sign-out-form") !== null,
    };
  `,
    { timeoutMs: 5_000, what: "the account menu to open" },
  );

  if (!opened.avatar) throw new Error("the account menu's trigger has no avatar");
  if (opened.initials.length === 0) throw new Error("the avatar has no initials");
  if (opened.name.length === 0) throw new Error("the account menu is not named in words");
  const wanted = ["account", "preferences", "sign-out"];
  for (const id of wanted) {
    if (!opened.ids.some((each) => each.endsWith(id))) {
      throw new Error(`the account menu has no "${id}" item (${opened.ids.join(", ")})`);
    }
  }
  if (opened.short > 0) throw new Error(`${opened.short} account item(s) under 36px`);
  if (!opened.form) throw new Error("Sign out has no form to carry the request");

  const moved = shifted(before, await measureChrome(session));
  if (moved.length > 0) {
    throw new Error(`opening the account menu moved the frame: ${moved.join("; ")}`);
  }

  await pressKey(session, "Escape", { windowsVirtualKeyCode: 27 });
  const closed = await waitFor(
    session,
    `
    const panel = document.getElementById("client-account-menu-list");
    if (panel === null || !panel.hasAttribute("hidden")) return null;
    const trigger = document.getElementById("client-account-menu-button");
    if (trigger.getAttribute("aria-expanded") !== "false") return null;
    return { focused: document.activeElement === null ? null : document.activeElement.id };
  `,
    { timeoutMs: 5_000, what: "Escape to close the account menu" },
  );
  if (closed.focused !== "client-account-menu-button") {
    throw new Error(`focus went to "${closed.focused ?? "(none)"}", not back to the avatar`);
  }

  return `${opened.labels.join(", ")}; Escape closed it and returned focus`;
}

// ---------------------------------------------------------------------------
// The Initiatives index's own writes (m04.02 item 8.14): sort, reverse, drag,
// and the Archived and Trash drawer. Each check seeds throwaway Initiatives
// through the page's own session, drives the real controls, times the
// acknowledgement the way the tree harness does (§6: under 100ms, before the
// reply), asks the server what it holds after each write, and trashes what it
// made — on a failure too.
// ---------------------------------------------------------------------------

/**
 * `sort_initiatives/2` for the rows a check seeded: their ids in the order the
 * page must show them. Recent keeps the server's order; Manual follows
 * `sort_order` with unplaced rows last; the rest sort ascending on their key,
 * ties keeping server order; Reverse flips the whole result.
 */
export function indexOrder(rows, mode, reverse = false) {
  const key = (row) => {
    switch (mode) {
      case "name":
        return (row.name ?? "").toLowerCase();
      case "progress":
        return row.progress ?? 0;
      case "created":
        return row.created_at;
      case "updated":
        return row.updated_at;
      default:
        return 0;
    }
  };
  let sorted;
  if (mode === "") {
    sorted = [...rows];
  } else if (mode === "manual") {
    const placed = rows.filter((row) => row.sort_order !== null).sort((a, b) => a.sort_order - b.sort_order);
    sorted = [...placed, ...rows.filter((row) => row.sort_order === null)];
  } else {
    sorted = [...rows].sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0));
  }
  const ids = sorted.map((row) => row.id);
  return reverse ? ids.reverse() : ids;
}

const sameIds = (a, b) => Array.isArray(a) && a.length === b.length && a.every((id, i) => id === b[i]);
/** The same rule as a page expression, for a stopwatch predicate. */
const SAME_IDS = "((a, b) => Array.isArray(a) && a.length === b.length && a.every((id, i) => id === b[i]))";

/** A page expression: the seeded ids, in the order the index shows them. */
function shownOrder(ids) {
  return `[...document.querySelectorAll("#initiatives > [data-initiative-id]")].map((el) => Number(el.dataset.initiativeId)).filter((id) => ${JSON.stringify(ids)}.includes(id))`;
}

/** A read through the page's own session: the `data` of `/app/api<path>`. */
async function pageRead(session, path) {
  const reply = await evaluate(
    session,
    `
    return (async () => {
      const response = await fetch(${JSON.stringify(`/app/api${path}`)}, { headers: { accept: "application/json" }, credentials: "same-origin" });
      if (!response.ok) return { ok: false, why: "the read of ${path} answered " + response.status };
      return { ok: true, data: (await response.json()).data };
    })();
  `,
  );
  if (!reply.ok) throw new Error(reply.why);
  return reply.data;
}

/** The index, freshly loaded in our own tab, with the fetch tap installed. */
async function openIndex(ctx, ready) {
  const { session } = ctx;
  await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives` });
  await waitFor(session, `return window.__doit_client_ready === true && (() => { ${ready} })() ? true : null;`, {
    timeoutMs: READY_TIMEOUT_MS,
    what: "the index to come up",
  });
  await evaluate(session, OPS_TAP);
}

/** Every reply landed and nothing in flight. */
async function indexSettled(session) {
  await waitFor(session, `const ops = window.__ops; return ops.inflight === 0 && ops.sent === ops.replied ? true : null;`, {
    timeoutMs: 10_000,
    everyMs: 20,
    what: "the index's writes to land",
  });
}

async function seedInitiatives(session, stamp, names) {
  const results = await pageOperations(
    session,
    `cdp-index-${stamp}-seed-${names.length}`,
    names.map((name) => ({ op: "add", type: "initiative", data: { name } })),
  );
  const ids = results.map((r) => r?.data?.id);
  if (!ids.every((id) => typeof id === "number")) throw new Error(`the seed did not name ${names.length} Initiatives: ${JSON.stringify(results)}`);
  return ids;
}

async function trashInitiatives(session, stamp, ids, label) {
  if (ids.length === 0) return;
  await pageOperations(
    session,
    `cdp-index-${stamp}-trash-${label}`,
    ids.map((id) => ({ op: "update", type: "initiative", id, data: { state: "trashed" } })),
  );
}

/**
 * Sort, Reverse and a drag. Three throwaway rows whose name, progress and
 * creation orders all differ; every mode of the Sort control reorders them on
 * the spot and the account remembers it; Reverse flips them both ways; a drag
 * of the last to the top lands in Manual before the reply and the server's
 * order agrees. The operator's own sort choice is put back at the end.
 */
export async function checkIndexSortAndDrag(ctx) {
  const { session } = ctx;
  const stamp = Date.now();
  // Created in this order, named out of it, progressed out of both.
  const names = [`CDP index B ${stamp}`, `CDP index C ${stamp}`, `CDP index A ${stamp}`];
  let ids = [];
  // On the app first: the page's own session does the seeding and the reads.
  await openIndex(ctx, "return true;");
  const saved = (await pageRead(session, "/session")).preferences ?? {};
  const savedMode = saved.index_sort ?? "";

  try {
    ids = await seedInitiatives(session, stamp, names);
    const [b, c, a] = ids;
    await pageOperations(session, `cdp-index-${stamp}-progress`, [
      { op: "add", type: "task", data: { initiative_id: c, title: "quarter", manual_progress: 25 } },
      { op: "add", type: "task", data: { initiative_id: b, title: "three quarters", manual_progress: 75 } },
    ]);
    // Recent for the run, whatever the operator keeps, so the seeded rows sit
    // together and the Sort control's own changes are what is measured.
    await pageOperation(session, `cdp-index-${stamp}-recent`, { op: "update", type: "account", data: { index_sort: null } });

    await openIndex(ctx, `return ${JSON.stringify(ids)}.every((id) => document.getElementById("initiatives-" + id) !== null);`);
    const rows = (await pageRead(session, "/initiatives")).filter((row) => ids.includes(row.id));
    if (rows.length !== 3) throw new Error(`the index read holds ${rows.length} of the 3 seeded rows`);
    const progress = Object.fromEntries(rows.map((row) => [row.id, row.progress]));
    if (progress[b] !== 75 || progress[c] !== 25 || progress[a] !== 0) throw new Error(`the seeded progress reads ${JSON.stringify(progress)}, not 75 / 25 / 0`);
    await waitFor(session, `return ${JSON.stringify(ids)}.every((id) => document.querySelector("#initiatives-" + id + " [role=progressbar]")?.getAttribute("aria-valuenow") === String(${JSON.stringify(progress)}[id])) ? true : null;`, {
      timeoutMs: 10_000,
      what: "the seeded progress on the cards",
    });

    const timings = [];
    const choose = (mode) =>
      evaluate(
        session,
        `
        const select = document.getElementById("initiative-sort-mode");
        select.focus();
        select.value = ${JSON.stringify(mode)};
        select.dispatchEvent(new Event("change", { bubbles: true }));
        return true;
      `,
      );
    const pick = async (mode, expected) => {
      const current = await evaluate(session, `return { mode: document.getElementById("initiative-sort-mode").value, shown: ${shownOrder(ids)} };`);
      if (current.mode === mode) return (await pageRead(session, "/session")).preferences?.index_sort_reverse === true;
      // Two modes can agree on these three rows; then there is nothing to
      // time, and only the save is checked.
      const moves = !sameIds(current.shown, expected);
      if (moves) await armStopwatch(session, "change", `return ${SAME_IDS}(${shownOrder(ids)}, ${JSON.stringify(expected)});`);
      const sent = await evaluate(session, `return window.__ops.sent;`);
      await choose(mode);
      if (moves) {
        const ack = await readStopwatch(session, `the index sorted by ${JSON.stringify(mode || "Recent")}`);
        // A mode the account keeps reversed flips once more when the reply
        // says so — the one change after the reply the client cannot know before it.
        if (ack.flips === 2 && ack.replyMs !== null && ack.trace.flips[1].t >= ack.replyMs) {
          if (ack.ackMs > 100) throw new Error(`the ${mode} order took ${ack.ackMs}ms to show`);
        } else {
          assertAcknowledged(ack, `the ${mode || "Recent"} order`);
        }
        timings.push(`${mode || "Recent"} ${ack.ackMs}ms`);
      } else {
        await waitFor(session, `return window.__ops.sent > ${sent} ? true : null;`, { timeoutMs: 5_000, everyMs: 10, what: `the ${mode || "Recent"} save to go out` });
        timings.push(`${mode || "Recent"} (same order)`);
      }
      await indexSettled(session);
      const prefs = (await pageRead(session, "/session")).preferences ?? {};
      if ((prefs.index_sort ?? "") !== mode) throw new Error(`the account saved sort ${JSON.stringify(prefs.index_sort)}, not ${JSON.stringify(mode)}`);
      return prefs.index_sort_reverse === true;
    };
    const flipReverse = async (mode, expected, on) => {
      await armStopwatch(session, "click", `return ${SAME_IDS}(${shownOrder(ids)}, ${JSON.stringify(expected)});`);
      await clickElement(session, '#initiative-sort input[name="reverse"]');
      const ack = await readStopwatch(session, `the ${mode} order reversed ${on ? "on" : "off"}`);
      assertAcknowledged(ack, `Reverse ${on ? "on" : "off"}`);
      await indexSettled(session);
      const prefs = (await pageRead(session, "/session")).preferences ?? {};
      if (prefs.index_sort !== mode || prefs.index_sort_reverse !== on) throw new Error(`the account saved ${JSON.stringify(prefs)} after Reverse ${on ? "on" : "off"}`);
      timings.push(`reverse ${on ? "on" : "off"} ${ack.ackMs}ms`);
    };

    // Every mode, ascending as the account last had it; Name gets Reverse both ways.
    for (const mode of ["name", "progress", "created", "updated"]) {
      const reverse = await pick(mode, indexOrder(rows, mode, false));
      // The account may keep this mode reversed: the page then shows it so.
      if (reverse) {
        const shown = await evaluate(session, `return ${shownOrder(ids)};`);
        if (!sameIds(shown, indexOrder(rows, mode, true))) throw new Error(`${mode} reversed shows ${JSON.stringify(shown)}`);
      }
      if (mode === "name") {
        await flipReverse(mode, indexOrder(rows, mode, !reverse), !reverse);
        await flipReverse(mode, indexOrder(rows, mode, reverse), reverse);
      }
    }

    // Manual, then the last seeded card dragged above the first.
    const manualReverse = await pick("manual", indexOrder(rows, "manual", false));
    const before = await evaluate(session, `return ${shownOrder(ids)};`);
    const source = before[before.length - 1];
    const anchor = before[0];
    const expected = movedBefore(before, source, anchor);
    // The throwaway cards sit at the end of a long list: bring the source
    // on screen before measuring, or the pointer lands on nothing.
    const handle = await evaluate(session, `const h = document.getElementById("init-drag-${source}"); h.scrollIntoView({ block: "center" }); const r = h.getBoundingClientRect(); return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + r.height / 2) };`);
    await mouseMove(session, handle);
    await mouseDown(session, handle);
    const pointer = { x: handle.x, y: handle.y + 12 };
    await mouseGlide(session, handle, pointer, 3);
    await waitFor(session, `return document.getElementById("initiatives-${source}").style.opacity === "0.5" ? true : null;`, { timeoutMs: 2_000, everyMs: 10, what: "the card drag to begin" });
    // The upper part of the first card, far enough in that the marker's own
    // height (inserted above it) leaves the pointer on the card.
    const target = await evaluate(session, `const r = document.getElementById("initiatives-${anchor}").getBoundingClientRect(); return { x: Math.round(r.x + r.width / 2), y: Math.round(r.y + 24) };`);
    await mouseGlide(session, pointer, target, 4);
    await mouseMove(session, target, { pressed: true });
    await waitFor(session, `const ph = document.querySelector("#initiatives > .init-drop-placeholder"); return ph !== null && ph.nextElementSibling?.id === "initiatives-${anchor}" ? true : null;`, { timeoutMs: 2_000, everyMs: 10, what: "the drop placeholder above the first card" });
    await armStopwatch(session, "pointerup", `return ${SAME_IDS}(${shownOrder(ids)}, ${JSON.stringify(expected)});`);
    await mouseUp(session, target);
    const dropped = await readStopwatch(session, "the dragged card in its new slot");
    assertAcknowledged(dropped, "the dropped card");
    await indexSettled(session);
    const after = (await pageRead(session, "/initiatives")).filter((row) => ids.includes(row.id));
    const stored = indexOrder(after, "manual", false);
    const shownStored = manualReverse ? [...expected].reverse() : expected;
    if (!sameIds(stored, shownStored)) throw new Error(`the server's manual order is ${JSON.stringify(stored)}, not ${JSON.stringify(shownStored)}`);
    timings.push(`drag ${dropped.ackMs}ms (${dropped.replyMs - dropped.ackMs}ms before the reply)`);

    // The operator's own sort, back through the same control.
    await pick(savedMode, indexOrder(after, savedMode, saved.index_sort_reverse === true));
    return timings.join(", ");
  } finally {
    await trashInitiatives(session, stamp, ids, "sort").catch((error) => {
      process.stdout.write(`LEAK  index sort rows could not be trashed: ${error.message}\n`);
    });
    await pageOperation(session, `cdp-index-${stamp}-restore-sort`, {
      op: "update",
      type: "account",
      data: { index_sort: savedMode === "" ? null : savedMode, index_sort_reverse: saved.index_sort_reverse === true },
    }).catch(() => {});
  }
}

/**
 * The Archived and Trash drawer. Four throwaway rows put away by the API — one
 * hidden, one archived, two in Trash — then, from the drawer: Show hidden and
 * Show trash reveal them without a fetch; Unhide, Restore and the Trash's
 * Restore each move the row onto the index before the reply; Delete asks
 * first, client-side, and the row is gone for good once confirmed. The server
 * is asked after each write.
 */
export async function checkIndexDrawer(ctx) {
  const { session } = ctx;
  const stamp = Date.now();
  let ids = [];
  let deleted = false;
  await openIndex(ctx, "return true;");

  try {
    ids = await seedInitiatives(session, stamp, ["hidden", "archived", "trashed", "deleted"].map((what) => `CDP drawer ${what} ${stamp}`));
    const [hidden, archived, trashed, doomed] = ids;
    await pageOperations(session, `cdp-index-${stamp}-put-away`, [
      { op: "update", type: "initiative", id: hidden, data: { state: "hidden" } },
      { op: "update", type: "initiative", id: archived, data: { state: "archived" } },
      { op: "update", type: "initiative", id: trashed, data: { state: "trashed" } },
      { op: "update", type: "initiative", id: doomed, data: { state: "trashed" } },
    ]);

    await openIndex(ctx, `return document.querySelector("#archived summary") !== null;`);
    const sentBefore = await evaluate(session, `return window.__ops.sent;`);
    await clickElement(session, "#archived summary");
    await waitFor(session, `return document.getElementById("archived").open ? true : null;`, { timeoutMs: 2_000, what: "the drawer to open" });
    // Show hidden and Show trash: the viewer's own view, nothing sent.
    await clickElement(session, "#show-hidden");
    await waitFor(session, `return document.getElementById("archived-${hidden}") !== null ? true : null;`, { timeoutMs: 2_000, everyMs: 10, what: "the hidden row under Show hidden" });
    await clickElement(session, "#show-trash");
    await waitFor(session, `return document.getElementById("trashed-${trashed}") !== null && document.getElementById("trashed-${doomed}") !== null ? true : null;`, { timeoutMs: 2_000, everyMs: 10, what: "the Trash rows under Show trash" });
    const sentAfter = await evaluate(session, `return window.__ops.sent;`);
    if (sentAfter !== sentBefore) throw new Error(`opening the drawer and its Show boxes sent ${sentAfter - sentBefore} operation(s)`);
    if (await evaluate(session, `return document.getElementById("archived-${archived}") === null;`)) throw new Error("the archived row is not in the drawer");

    const timings = [];
    const moveOut = async (button, id, what) => {
      await armStopwatch(session, "click", `return document.getElementById("initiatives-${id}") !== null && document.getElementById("archived-${id}") === null && document.getElementById("trashed-${id}") === null;`);
      await clickElement(session, button);
      const ack = await readStopwatch(session, `${what} onto the index`);
      assertAcknowledged(ack, what);
      await indexSettled(session);
      const archive = await pageRead(session, "/initiatives/archive");
      const still = archive.archived.some((row) => row.id === id) || archive.trashed.some((row) => row.id === id);
      if (still) throw new Error(`the server still holds the ${what} row put away`);
      const live = (await pageRead(session, "/initiatives")).some((row) => row.id === id);
      if (!live) throw new Error(`the server's index does not list the ${what} row`);
      timings.push(`${what} ${ack.ackMs}ms`);
    };
    await moveOut(`#archived-${hidden}-unhide`, hidden, "Unhide");
    await moveOut(`#archived-${archived}-restore`, archived, "Restore");
    await moveOut(`#trashed-${trashed}-restore`, trashed, "Trash's Restore");

    // Delete: the confirm opens on the spot and sends nothing; Delete in it empties the slot.
    const sentBeforeDelete = await evaluate(session, `return window.__ops.sent;`);
    await armStopwatch(session, "click", `return document.getElementById("purge-initiative-confirm")?.open === true;`);
    await clickElement(session, `#trashed-${doomed}-delete`);
    const asked = await readStopwatch(session, "the Delete forever confirm", { expectReply: false });
    assertAcknowledged(asked, "the confirm");
    if ((await evaluate(session, `return window.__ops.sent;`)) !== sentBeforeDelete) throw new Error("opening the confirm sent an operation");
    await armStopwatch(session, "click", `return document.getElementById("trashed-${doomed}") === null && document.getElementById("initiatives-${doomed}") === null;`);
    await clickElement(session, "#purge-initiative-confirm-confirm");
    const purged = await readStopwatch(session, "the deleted row gone");
    assertAcknowledged(purged, "the deleted row");
    await indexSettled(session);
    const archive = await pageRead(session, "/initiatives/archive");
    if (archive.trashed.some((row) => row.id === doomed)) throw new Error("the server still holds the deleted row in Trash");
    if ((await pageRead(session, "/initiatives")).some((row) => row.id === doomed)) throw new Error("the deleted row is back on the server's index");
    deleted = true;
    timings.push(`confirm ${asked.ackMs}ms, Delete ${purged.ackMs}ms`);
    return timings.join(", ");
  } finally {
    // The three back on the index go to Trash; the fourth is deleted here if the check did not get to it.
    await trashInitiatives(session, stamp, ids.slice(0, 3), "drawer").catch((error) => {
      process.stdout.write(`LEAK  index drawer rows could not be trashed: ${error.message}\n`);
    });
    if (!deleted && ids.length === 4) {
      await pageOperation(session, `cdp-index-${stamp}-purge`, { op: "remove", type: "initiative", id: ids[3] }).catch(() => {});
    }
  }
}

const CHECKS = [
  ["client ready", checkClientReady],
  ["no layout shift", checkNoLayoutShift],
  ["skeleton row == real row", checkSkeletonMatchesRow],
  ["theme both ways", checkThemeBothWays],
  ["notifications bell", checkBell],
  ["account menu", checkAccountMenu],
  ["keyboard traversal of the frame", checkKeyboardTraversal],
  ["reduced motion", checkReducedMotion],
  ["nav click \u2192 Assigned to Me", checkNavClickToAssigned],
  ["no shift across routes", checkNoShiftAcrossRoutes],
  ["deep link, back and forward", checkDeepLinkAndHistory],
  ["index: sort, reverse, drag", checkIndexSortAndDrag],
  ["index: hidden, archived, trash", checkIndexDrawer],
  ["acknowledgement under latency", checkAckUnderLatency],
  ["narrow viewport menu", checkNarrowMenu],
  ["menu sign out reaches the form", checkMenuSignOutSubmits],
  ["dialog focus return", checkDialogFocusReturn],
  ["disconnected startup", checkDisconnectedStartup],
  // Near-last: it takes the network away and back, so nothing after it inherits
  // a throttled tab.
  ["connection summary", checkConnectionSummary],
  // Truly last: it reports what the run left on the operator's device.
  ["no harness residue", checkNoHarnessResidue],
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
    // The main column is SUPPOSED to get taller as content lands; what must not
    // change is where it starts and how wide it is. So it is measured without
    // its height.
    const column = (el) => {
      const b = box(el);
      return b === null ? null : { x: b.x, y: b.y, w: b.w };
    };
    return {
      header: box(document.getElementById("client-header")),
      nav: box(document.getElementById("client-nav")),
      main: column(document.getElementById("client-main")),
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
// Target acquisition: the one tab, reused and left open — the same rule as
// check_tree.mjs (`pickTarget`). Nothing here ever closes a tab.
// ---------------------------------------------------------------------------

/**
 * Get a target AND a live session on it. The browser calls are injected so the
 * shape is unit-testable — see `check_client.test.mjs`.
 */
export async function acquireSession({ acquire, attach }) {
  const target = await acquire();
  return { target, session: await attach(target.webSocketDebuggerUrl) };
}

async function acquireTarget() {
  const existing = pickTarget(await listTargets(CDP_URL), APP_URL);
  if (existing !== null) {
    process.stdout.write(`tab   reusing ${existing.url}\n`);
    return existing;
  }
  const opened = await openTarget(CDP_URL, "about:blank");
  if (!opened?.webSocketDebuggerUrl) throw new Error("no webSocketDebuggerUrl in the /json/new reply");
  process.stdout.write("tab   opened a new one (none was on the app); it stays open\n");
  return opened;
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

  const { session } = await acquireSession({
    acquire: acquireTarget,
    attach: (wsUrl) => connect(wsUrl),
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

    // CDP_FROM=<substring>: skip the checks before the first whose name has it.
    let reached = process.env.CDP_FROM === undefined;
    for (const [name, check] of CHECKS) {
      const started = Date.now();
      reached ||= name.includes(process.env.CDP_FROM);
      if (!reached) {
        results.push({ name, status: "SKIP", ms: 0, note: `before CDP_FROM "${process.env.CDP_FROM}"` });
        continue;
      }
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
