#!/usr/bin/env node
// The tree harness (m04.02 item 7.3): drive a REAL browser through the client's
// own tree at `/app/initiatives/:id` and report PASS/FAIL for add, edit,
// completion, the cascade confirm, delete, undo and redo.
//
// Opt-in, like `check_client.mjs`: NOT part of `mix test` or `mix precommit`.
//
//   CDP_URL       DevTools endpoint          (default http://localhost:9222)
//   APP_URL       app origin                 (default http://localhost:4000)
//   CDP_OPTIONAL  =1 → exit 0 when no endpoint answers (default: exit 2)
//
// ONE tab, for every check and every run: the tab already open on APP_URL is
// reused (a new one is opened only when there is none), every step navigates
// within it, and it is left open on the Initiatives index at the end. It is
// never closed and never duplicated.
//
// It runs from the HOST: the container cannot reach the operator's bridge.
// Node 22+ (or Node 20 with --experimental-websocket) — it needs global WebSocket.
//
// Everything happens inside ONE throwaway Initiative, "CDP check <timestamp>",
// created through the page's own session (item 7.3.1) and trashed in a
// `finally` — trashed even when a check fails, and never touched if it could
// not be created. No existing Initiative is opened or changed.
//
// Two things every check asserts (UX_GUARDRAILS §6):
//
//   * instant acknowledgement — the DOM shows the outcome (or the in-flight
//     mark) BEFORE the operation's reply, timed in the page by a
//     MutationObserver against the click that asked for it. The link carries
//     an emulated latency for the whole run so "before the reply" is a fact,
//     not a race the network happened to win;
//   * the canonical settle — every pending mark (`is-saving`,
//     `is-recomputing`, a stand-in id) is gone once the replies land, and what
//     was shown never went away in between (no flicker).
//
// Every check is one exported async function taking the shared context, listed
// in CHECKS below, in the order they run: each builds on the tree the last one
// left.

import { mkdir, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  browserVersion,
  clickElement,
  connect,
  evaluate,
  listTargets,
  openTarget,
  pressKey,
  waitFor,
} from "./cdp.mjs";

const CDP_URL = (process.env.CDP_URL ?? "http://localhost:9222").replace(/\/$/, "");
const APP_URL = (process.env.APP_URL ?? "http://localhost:4000").replace(/\/$/, "");
const VIEWPORT = { width: 1280, height: 800 };
const READY_TIMEOUT_MS = 15_000;
const SHOT_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "../../tmp/cdp");

/** How long after the click the outcome (or the wait) must be on the glass. */
const ACK_BUDGET_MS = 100;
/** Put on the link for the run: a reply cannot beat a same-frame paint by luck. */
const LINK_LATENCY_MS = 400;
const FAST_LINK = { offline: false, latency: 0, downloadThroughput: -1, uploadThroughput: -1 };
/** Longer than the latency: the client's refetch on its own echo has started by then. */
const QUIET_MS = LINK_LATENCY_MS + 200;

const TITLES = {
  task: "Alpha",
  child: "Alpha child",
  renamed: "Alpha, renamed",
};

// ---------------------------------------------------------------------------
// Checks. One exported async function each; `ctx` carries the session, the
// throwaway's id and the ids the earlier checks learned.
// ---------------------------------------------------------------------------

/**
 * Add a top-level task: the row is on the glass before the reply, then settles
 * under its server id with nothing pending.
 */
export async function checkAddTask(ctx) {
  const { session } = ctx;

  await clickElement(session, "[data-add-root]");
  await waitFor(session, `return document.activeElement?.matches('#add-task-form input[name="title"]');`, {
    timeoutMs: 5_000,
    what: "the add form to take focus",
  });
  await session.send("Input.insertText", { text: TITLES.task });

  await armStopwatch(session, "click", `return __tree.row(${JSON.stringify(TITLES.task)}) !== null;`);
  await clickElement(session, '#add-task-form button[type="submit"]');
  const ack = await readStopwatch(session, "the new row");
  assertAcknowledged(ack, "the new row");

  const settled = await settle(session);
  const row = await evaluate(
    session,
    `
    const li = __tree.row(${JSON.stringify(TITLES.task)});
    return li === null ? null : { id: Number(li.dataset.taskId), depth: li.dataset.depth };
  `,
  );
  if (row === null) throw new Error("the row is gone after the reply");
  if (!(row.id > 0)) throw new Error(`the row still carries a stand-in id (${row.id})`);
  if (row.depth !== "0") throw new Error(`the row landed at depth ${row.depth}, not the top`);
  ctx.ids.task = row.id;

  // The form stays open for the next title, as the LiveView's does.
  await pressKey(session, "Escape");
  return `row shown ${ack.ackMs}ms after the click, ${ack.replyMs - ack.ackMs}ms before the reply; settled as #${row.id} with ${settled.note}`;
}

/** Add a child under the first task: it lands inside that branch. */
export async function checkAddChild(ctx) {
  const { session } = ctx;
  const parentId = ctx.ids.task;

  await clickElement(session, `#task-${parentId} [data-add-child="${parentId}"]`);
  await waitFor(session, `return document.activeElement?.matches('#add-task-form input[name="title"]');`, {
    timeoutMs: 5_000,
    what: "the subtask form to take focus",
  });
  await session.send("Input.insertText", { text: TITLES.child });

  await armStopwatch(
    session,
    "click",
    `
    const li = __tree.row(${JSON.stringify(TITLES.child)});
    return li !== null && li.closest("#children-${parentId}") !== null;
  `,
  );
  await clickElement(session, '#add-task-form button[type="submit"]');
  const ack = await readStopwatch(session, "the child row");
  assertAcknowledged(ack, "the child row");

  const settled = await settle(session);
  const child = await evaluate(
    session,
    `
    const li = __tree.row(${JSON.stringify(TITLES.child)});
    if (li === null) return null;
    return { id: Number(li.dataset.taskId), under: li.closest("#children-${parentId}") !== null };
  `,
  );
  if (child === null) throw new Error("the child row is gone after the reply");
  if (!(child.id > 0)) throw new Error(`the child still carries a stand-in id (${child.id})`);
  if (!child.under) throw new Error("the child settled outside its parent's branch");
  ctx.ids.child = child.id;

  await pressKey(session, "Escape");
  return `child shown ${ack.ackMs}ms after the click, ${ack.replyMs - ack.ackMs}ms before the reply; settled as #${child.id} with ${settled.note}`;
}

/** Rename through the Details pane: the row's title follows the field at once. */
export async function checkEditTitle(ctx) {
  const { session } = ctx;
  const id = ctx.ids.task;

  await selectRow(session, id);
  await clickElement(session, "#task-field-title");
  await evaluate(session, `document.getElementById("task-field-title").select(); return true;`);
  await session.send("Input.insertText", { text: TITLES.renamed });

  // Enter blurs the field, and the blur commits — t0 is the Enter itself.
  await armStopwatch(
    session,
    "keydown",
    `
    const li = __tree.row(${JSON.stringify(TITLES.renamed)});
    if (li === null) return false;
    return { saving: li.querySelector(":scope > [data-task-row]").classList.contains("is-saving") };
  `,
  );
  await pressKey(session, "Enter");
  const ack = await readStopwatch(session, "the renamed row");
  assertAcknowledged(ack, "the renamed row");
  if (!ack.detail?.saving) throw new Error("the row was not marked saving while the rename was in flight");

  const settled = await settle(session);
  const title = await evaluate(session, `return __tree.title(${id});`);
  if (title !== TITLES.renamed) throw new Error(`the row settled as "${title}"`);
  const field = await evaluate(session, `return document.getElementById("task-field-title")?.value ?? null;`);
  if (field !== TITLES.renamed) throw new Error(`the pane's field settled as "${field}"`);

  return `title on the glass ${ack.ackMs}ms after Enter, ${ack.replyMs - ack.ackMs}ms before the reply; settled with ${settled.note}`;
}

/**
 * Complete the leaf: it is done at once, and its parent's roll-up is predicted
 * (100% over one done leaf) with the bar marked recomputing until the number
 * comes back.
 */
export async function checkCompleteLeaf(ctx) {
  const { session } = ctx;
  const { task: parentId, child: childId } = ctx.ids;

  const before = await evaluate(session, `return __tree.progress(${parentId});`);
  await armStopwatch(
    session,
    "click",
    `
    const child = __tree.rowEl(${childId});
    const parent = __tree.rowEl(${parentId});
    if (child === null || parent === null) return false;
    if (child.dataset.done !== "true") return false;
    return {
      parentProgress: parent.dataset.taskProgress,
      parentRecomputing: parent.classList.contains("is-recomputing"),
      childSaving: child.classList.contains("is-saving"),
    };
  `,
  );
  await clickElement(session, `#task-${childId} [data-complete-toggle]`);
  const ack = await readStopwatch(session, "the leaf to show done");
  assertAcknowledged(ack, "the done leaf");
  if (ack.detail.parentProgress !== "100") {
    throw new Error(`the parent predicted ${ack.detail.parentProgress}% over one done leaf, not 100%`);
  }
  if (!ack.detail.parentRecomputing) throw new Error("the parent's bar was not marked recomputing");
  if (!ack.detail.childSaving) throw new Error("the leaf was not marked saving");

  const settled = await settle(session);
  const after = await evaluate(
    session,
    `
    return {
      childDone: __tree.rowEl(${childId})?.dataset.done === "true",
      parentProgress: __tree.progress(${parentId}),
      parentDone: __tree.rowEl(${parentId})?.dataset.done === "true",
    };
  `,
  );
  if (!after.childDone) throw new Error("the leaf is not done after the reply");
  if (after.parentProgress !== "100") throw new Error(`the parent settled at ${after.parentProgress}%`);

  return `done ${ack.ackMs}ms after the click, ${ack.replyMs - ack.ackMs}ms before the reply; parent ${before}% → ${after.parentProgress}%, settled with ${settled.note}`;
}

/**
 * Completing a branch asks first (item 5.1.4, §6.5): the cascade confirm opens
 * at once, nothing is sent, and Cancel leaves the tree exactly as it was.
 */
export async function checkCascadeConfirmCancel(ctx) {
  const { session } = ctx;
  const { task: parentId, child: childId } = ctx.ids;

  // The parent is done since its one leaf is; reopen the leaf first (a leaf
  // toggle never asks) so the parent's toggle is a completion, not a reopen.
  await armStopwatch(session, "click", `const el = __tree.rowEl(${childId}); return el !== null && el.dataset.done !== "true";`);
  await clickElement(session, `#task-${childId} [data-complete-toggle]`);
  assertAcknowledged(await readStopwatch(session, "the leaf to show open"), "the reopened leaf");
  await settle(session);
  const parentDone = await evaluate(session, `return __tree.rowEl(${parentId})?.dataset.done ?? "";`);
  if (parentDone === "true") throw new Error("the parent still reads done over one open leaf");

  const before = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  await armStopwatch(
    session,
    "click",
    `
    const dialog = document.getElementById("cascade-confirm");
    return dialog !== null && dialog.open ? { title: dialog.querySelector("h2")?.textContent.trim() } : false;
  `,
    { transient: true },
  );
  await clickElement(session, `#task-${parentId} [data-complete-toggle]`);
  const ack = await readStopwatch(session, "the cascade confirm", { expectReply: false });
  if (ack.ackMs > ACK_BUDGET_MS) throw new Error(`the confirm took ${ack.ackMs}ms to open`);
  if (ack.detail.title !== "Complete this branch?") {
    throw new Error(`the confirm is titled "${ack.detail.title}"`);
  }

  const held = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  if (held.sent !== before.sent) throw new Error("an operation was sent while the question was open");
  if (held.tree !== before.tree) throw new Error("the tree changed while the question was open");

  await clickElement(session, "#cascade-confirm-cancel");
  await waitFor(session, `return document.getElementById("cascade-confirm")?.open === false;`, {
    timeoutMs: 5_000,
    what: "the confirm to close",
  });
  // Nothing was queued, so there is nothing to wait for — but give a wrongly
  // sent operation the time it would need to show up.
  await new Promise((done) => setTimeout(done, LINK_LATENCY_MS));
  const after = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  if (after.sent !== before.sent) throw new Error("Cancel sent an operation");
  if (after.tree !== before.tree) throw new Error("Cancel changed the tree");

  return `leaf reopened first; confirm open ${ack.ackMs}ms after the click; nothing sent; Cancel left the tree as it was`;
}

/**
 * Delete from the Details pane: the row is gone at once. The client asks no
 * question of its own today; if one ever opens, it is answered and said.
 */
export async function checkDelete(ctx) {
  const { session } = ctx;
  const childId = ctx.ids.child;

  await selectRow(session, childId);
  await waitFor(session, `return document.getElementById("delete-task-btn") !== null;`, {
    timeoutMs: 5_000,
    what: "the Delete button",
  });

  await armStopwatch(session, "click", `return __tree.rowEl(${childId}) === null;`);
  await clickElement(session, "#delete-task-btn");

  // A confirm, if the client opens one, is the acknowledgement.
  const asked = await waitFor(
    session,
    `
    const dialog = document.querySelector("dialog[open]");
    if (dialog !== null) return { dialog: dialog.id };
    return __sw.at !== null ? { dialog: null } : null;
  `,
    { timeoutMs: 5_000, everyMs: 10, what: "the row to go, or a confirm to open" },
  );
  if (asked.dialog !== null) {
    await clickElement(session, `#${asked.dialog} button[id$="-confirm"]`);
  }

  const ack = await readStopwatch(session, "the row to go");
  if (asked.dialog === null) assertAcknowledged(ack, "the deleted row");
  else if (ack.replyMs !== null && ack.at > ack.replyAt) {
    throw new Error("the row waited for the reply after the confirm");
  }

  const settled = await settle(session);
  const gone = await evaluate(session, `return __tree.rowEl(${childId}) === null;`);
  if (!gone) throw new Error("the row came back after the reply");
  const paneOpen = await evaluate(session, `return document.getElementById("task-field-title") !== null;`);
  if (paneOpen) throw new Error("the Details pane is still open on a deleted task");

  const via = asked.dialog === null ? "no confirm asked" : `confirmed in #${asked.dialog}`;
  return `${via}; row gone ${ack.ackMs}ms after the click, ${ack.replyMs - ack.ackMs}ms before the reply; settled with ${settled.note}`;
}

/**
 * Undo puts the deleted row back. The press is acknowledged by the button
 * itself (§6.7) — the tree changes when the server says what it reversed.
 */
export async function checkUndo(ctx) {
  const { session } = ctx;
  const childId = ctx.ids.child;

  await armStopwatch(session, "click", `return document.getElementById("undo-button")?.getAttribute("aria-busy") === "true";`, { transient: true });
  await clickElement(session, "#undo-button");
  const ack = await readStopwatch(session, "the Undo button to show its wait");
  assertAcknowledged(ack, "the Undo wait");

  const settled = await settle(session);
  const restored = await evaluate(
    session,
    `
    const li = __tree.rowEl(${childId});
    return {
      back: li !== null,
      under: li !== null && li.closest("#children-${ctx.ids.task}") !== null,
      title: __tree.title(${childId}),
      busy: document.getElementById("undo-button")?.getAttribute("aria-busy"),
      disabled: document.getElementById("undo-button")?.disabled,
    };
  `,
  );
  if (!restored.back) throw new Error("the deleted row did not come back");
  if (!restored.under) throw new Error("the row came back outside its branch");
  if (restored.title !== TITLES.child) throw new Error(`the row came back as "${restored.title}"`);
  if (restored.busy === "true" || restored.disabled) throw new Error("the Undo button is still waiting");

  return `wait shown ${ack.ackMs}ms after the click, ${ack.replyMs - ack.ackMs}ms before the reply; row back, settled with ${settled.note}`;
}

/** Redo takes it away again. */
export async function checkRedo(ctx) {
  const { session } = ctx;
  const childId = ctx.ids.child;

  await armStopwatch(session, "click", `return document.getElementById("redo-button")?.getAttribute("aria-busy") === "true";`, { transient: true });
  await clickElement(session, "#redo-button");
  const ack = await readStopwatch(session, "the Redo button to show its wait");
  assertAcknowledged(ack, "the Redo wait");

  const settled = await settle(session);
  const after = await evaluate(
    session,
    `
    return {
      gone: __tree.rowEl(${childId}) === null,
      parentThere: __tree.rowEl(${ctx.ids.task}) !== null,
      busy: document.getElementById("redo-button")?.getAttribute("aria-busy"),
      disabled: document.getElementById("redo-button")?.disabled,
    };
  `,
  );
  if (!after.gone) throw new Error("the row is still there after Redo");
  if (!after.parentThere) throw new Error("Redo took the parent with it");
  if (after.busy === "true" || after.disabled) throw new Error("the Redo button is still waiting");

  return `wait shown ${ack.ackMs}ms after the click, ${ack.replyMs - ack.ackMs}ms before the reply; row gone again, settled with ${settled.note}`;
}

const CHECKS = [
  ["add a task", checkAddTask],
  ["add a child", checkAddChild],
  ["edit a title in the pane", checkEditTitle],
  ["complete a leaf, parent rolls up", checkCompleteLeaf],
  ["cascade confirm, Cancel", checkCascadeConfirmCancel],
  ["delete", checkDelete],
  ["undo", checkUndo],
  ["redo", checkRedo],
];

// ---------------------------------------------------------------------------
// In-page helpers. Installed once the tree is up; every check reads through them.
// ---------------------------------------------------------------------------

const PAGE_HELPERS = `
  window.__tree = {
    // The <li> whose OWN row carries this title (a child's row is nested deeper).
    row(title) {
      for (const li of document.querySelectorAll("#task-tree li[data-task-id]")) {
        const el = li.querySelector(":scope > [data-task-row] [data-task-title]");
        if (el !== null && el.textContent.trim() === title) return li;
      }
      return null;
    },
    rowEl(id) {
      return document.querySelector("#task-" + id + " > [data-task-row]");
    },
    title(id) {
      return document.querySelector("#task-" + id + " > [data-task-row] [data-task-title]")?.textContent.trim() ?? null;
    },
    progress(id) {
      return this.rowEl(id)?.dataset.taskProgress ?? null;
    },
    // Every row's id, done flag and progress, in document order.
    snapshot() {
      return [...document.querySelectorAll("#task-tree [data-task-row]")]
        .map((r) => r.parentElement.dataset.taskId + ":" + (r.dataset.done ?? "") + ":" + r.dataset.taskProgress)
        .join("|");
    },
    pending() {
      return {
        saving: document.querySelectorAll("#task-tree .is-saving").length,
        recomputing: document.querySelectorAll("#task-tree .is-recomputing").length,
        standIns: document.querySelectorAll('#task-tree li[data-task-id^="-"]').length,
      };
    },
  };

  // Every fetch the client makes, counted; operations replies stamped.
  if (window.__ops === undefined) {
    const original = window.fetch;
    window.__ops = { sent: 0, replied: 0, inflight: 0, replies: [], log: [], lastActivity: performance.now() };
    window.fetch = function (input, init) {
      const url = typeof input === "string" ? input : input.url;
      const method = (init?.method ?? "GET").toUpperCase();
      const isOp = method === "POST" && /\\/app\\/api\\/operations$/.test(url);
      const ops = window.__ops;
      ops.inflight += 1;
      ops.lastActivity = performance.now();
      if (isOp) ops.sent += 1;
      const entry = { method, url, start: Math.round(performance.now()), end: null };
      ops.log.push(entry);
      const settle = () => {
        ops.inflight -= 1;
        entry.end = Math.round(performance.now());
        ops.lastActivity = performance.now();
        if (isOp) {
          ops.replied += 1;
          ops.replies.push(performance.now());
        }
      };
      return original.call(this, input, init).then(
        (response) => {
          settle();
          if (isOp) response.clone().text().then((text) => { entry.reply = text.slice(0, 600); }).catch(() => {});
          return response;
        },
        (error) => { settle(); throw error; },
      );
    };
  }
  return true;
`;

/**
 * Arms the page's stopwatch: t0 is stamped on the next `trigger` event
 * (capture, so before any handler runs); `at` the first time `predicate`
 * (a function body over the DOM) holds, checked on every DOM mutation — a
 * microtask, so it is stamped before any reply's task can run. `flips` counts
 * every change of the predicate's truth, so "shown then gone then back" reads
 * as 3, not 1. A `transient` predicate (an in-flight mark, an open dialog) is
 * expected to stop holding, so `settle` does not read its flips as flicker.
 */
async function armStopwatch(session, trigger, predicate, { transient = false } = {}) {
  await evaluate(
    session,
    `
    if (window.__sw?.observer) window.__sw.observer.disconnect();
    const pred = () => { try { return (() => { ${predicate} })(); } catch { return false; } };
    const sw = {
      t0: null, at: null, detail: null, flips: 0, log: [], was: Boolean(pred()), observer: null,
      // A wait mark is MEANT to go away once the reply lands; a row is not.
      transient: ${transient},
    };
    window.__sw = sw;
    const look = () => {
      if (sw.t0 === null) return;
      const value = pred();
      const now = Boolean(value);
      if (now !== sw.was) {
        sw.flips += 1;
        sw.log.push({
          t: Math.round(performance.now() - sw.t0),
          holds: now,
          // What the tree held at that moment, for the failure report.
          rows: [...document.querySelectorAll("#task-tree li[data-task-id]")].map((li) => li.dataset.taskId + ":" + (li.querySelector(":scope > [data-task-row] [data-task-title]")?.textContent.trim() ?? "?")),
          skeleton: document.getElementById("initiative-tree-skeleton") !== null,
        });
        sw.was = now;
        if (now && sw.at === null) {
          sw.at = performance.now();
          sw.detail = typeof value === "object" ? value : null;
        }
      }
    };
    sw.observer = new MutationObserver(look);
    sw.observer.observe(document.body, { childList: true, subtree: true, attributes: true, characterData: true });
    document.addEventListener(${JSON.stringify(trigger)}, () => {
      sw.t0 = performance.now();
      // The handler may have painted synchronously, before any mutation
      // record is delivered: look once the click's own task is done.
      queueMicrotask(look);
    }, { capture: true, once: true });
    return true;
  `,
  );
}

/** Waits for `at` (and, unless told otherwise, the reply that followed t0). */
async function readStopwatch(session, what, { expectReply = true } = {}) {
  const read = await waitFor(
    session,
    `
    const sw = window.__sw;
    if (sw === undefined || sw.t0 === null || sw.at === null) return null;
    const replyAt = window.__ops.replies.find((t) => t > sw.t0) ?? null;
    if (${expectReply} && replyAt === null) return null;
    return {
      ackMs: Math.round(sw.at - sw.t0),
      at: sw.at,
      replyAt,
      replyMs: replyAt === null ? null : Math.round(replyAt - sw.t0),
      flips: sw.flips,
      transient: sw.transient,
      // A transient mark's second change is it going away; when, in ms after t0.
      goneMs: sw.log.length > 1 && !sw.log[1].holds ? sw.log[1].t : null,
      detail: sw.detail,
      // For the failure report: when the predicate changed, and every fetch since t0.
      trace: {
        flips: sw.log,
        fetches: window.__ops.log
          .filter((f) => f.start >= sw.t0 - 1)
          .map((f) => f.method + " " + f.url.replace(/^.*\\/app\\/api/, "") + " " + (f.start - Math.round(sw.t0)) + "→" + (f.end === null ? "…" : f.end - Math.round(sw.t0)) + (f.reply === undefined ? "" : " " + f.reply)),
      },
    };
  `,
    { timeoutMs: 10_000, everyMs: 10, what },
  );
  await evaluate(session, `window.__sw?.observer?.disconnect(); return true;`);
  return read;
}

function assertAcknowledged(ack, what) {
  if (ack.ackMs > ACK_BUDGET_MS) throw new Error(`${what} took ${ack.ackMs}ms to show`);
  if (ack.replyAt !== null && ack.at > ack.replyAt) {
    throw new Error(`${what} waited for the reply (shown ${ack.ackMs}ms, reply ${ack.replyMs}ms)`);
  }
  // A wait mark may be gone by the time the reply is read — but only after
  // the reply, never before it. Anything else shown must stay.
  if (ack.transient && ack.flips === 2 && ack.replyMs !== null && ack.goneMs >= ack.replyMs) return;
  if (ack.flips !== 1) {
    throw new Error(`${what} flickered: shown, then gone, ${ack.flips} changes in all — ${JSON.stringify(ack.trace)}`);
  }
}

/**
 * Every reply landed, the echo's refetch (if any) too, and nothing on the
 * tree is marked pending.
 */
async function settle(session) {
  const state = await waitFor(
    session,
    `
    const ops = window.__ops;
    if (ops.sent !== ops.replied || ops.inflight > 0) return null;
    // The client refetches on its own echo; let a refetch that is about to
    // start, start.
    if (performance.now() - ops.lastActivity < ${QUIET_MS}) return null;
    const pending = __tree.pending();
    if (pending.saving > 0 || pending.recomputing > 0 || pending.standIns > 0) return null;
    return { pending, sent: ops.sent };
  `,
    { timeoutMs: 15_000, everyMs: 50, what: "the tree to settle" },
  );
  const flips = await evaluate(
    session,
    `
    const sw = window.__sw;
    return sw === undefined || sw.transient ? null : { count: sw.flips, log: sw.log, fetches: window.__ops.log.slice(-6) };
  `,
  );
  if (flips !== null && flips.count !== 1) {
    throw new Error(`what was shown went away before it settled (${flips.count} changes) — ${JSON.stringify(flips)}`);
  }
  return { ...state, note: `no pending marks (${state.sent} op(s) sent)` };
}

/** Selects a row by clicking its title, and waits for the pane. */
async function selectRow(session, id) {
  await clickElement(session, `#task-${id} > [data-task-row] [data-task-title]`);
  await waitFor(
    session,
    `return document.querySelector("#task-${id}[data-selected]") !== null && document.getElementById("task-field-title") !== null;`,
    { timeoutMs: 5_000, what: `row #${id} to be selected with its pane open` },
  );
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
// The throwaway Initiative (item 7.3.1).
// ---------------------------------------------------------------------------

/**
 * Creates the throwaway, runs the checks in it, and trashes it — on success,
 * on a failed run, and even when the trashing itself is what fails, the run's
 * own error is the one reported — the leak goes to `onLeak`, so it is said and
 * not buried. A throwaway that could not be created is never trashed, because
 * there is nothing to trash. The browser calls are
 * injected so this rule is unit-testable — see `check_tree.test.mjs`.
 */
export async function withThrowaway({ create, run, trash, onLeak }) {
  const created = await create();
  let outcome;
  try {
    outcome = await run(created);
  } catch (error) {
    await trash(created).catch((cause) => onLeak?.(created, cause));
    throw error;
  }
  await trash(created);
  return outcome;
}

/** One batch through the page's own session — its cookie, its CSRF token. */
async function pageOperation(session, key, operation) {
  const reply = await evaluate(
    session,
    `
    return (async () => {
      const session = await fetch("/app/api/session", {
        headers: { accept: "application/json" },
        credentials: "same-origin",
      });
      if (!session.ok) return { ok: false, why: "the session read answered " + session.status };
      const token = (await session.json()).data?.csrf_token;
      if (typeof token !== "string") return { ok: false, why: "the session read carried no CSRF token" };
      const response = await fetch("/app/api/operations", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          accept: "application/json",
          "content-type": "application/json",
          "x-csrf-token": token,
          "idempotency-key": ${JSON.stringify(key)},
        },
        body: JSON.stringify({ operations: [${JSON.stringify(operation)}] }),
      });
      const body = await response.json().catch(() => null);
      const results = body?.data?.results ?? body?.results ?? [];
      if (!response.ok) return { ok: false, why: "answered " + response.status + ": " + JSON.stringify(body?.error ?? body) };
      return { ok: true, result: results[0] ?? null };
    })();
  `,
  );
  if (!reply.ok) throw new Error(`${operation.op} ${operation.type} ${reply.why}`);
  return reply.result;
}

async function createThrowaway(session, stamp) {
  const result = await pageOperation(session, `cdp-tree-${stamp}-create`, {
    op: "add",
    type: "initiative",
    data: { name: `CDP check ${stamp}` },
  });
  // `{index, status, data: {id, type, …}}` — the per-op result shape.
  const created = result?.data;
  if (result?.status !== "ok" || created?.type !== "initiative" || typeof created.id !== "number") {
    throw new Error(`the add initiative reply was not one: ${JSON.stringify(result)}`);
  }
  return { id: created.id, name: `CDP check ${stamp}` };
}

async function trashThrowaway(session, throwaway, stamp) {
  await pageOperation(session, `cdp-tree-${stamp}-trash`, {
    op: "update",
    type: "initiative",
    id: throwaway.id,
    data: { state: "trashed" },
  });
}

// ---------------------------------------------------------------------------
// Target acquisition: the one tab, reused and left open.
// ---------------------------------------------------------------------------

/** The page target to drive: one already on the app, else a fresh one. */
export function pickTarget(targets, appUrl) {
  const pages = targets.filter((t) => t.type === "page" && t.webSocketDebuggerUrl);
  const onApp = pages.filter((t) => typeof t.url === "string" && t.url.startsWith(`${appUrl}/`));
  // One that is not looking at an Initiative's tree comes first: the run
  // navigates away from wherever it starts.
  return onApp.find((t) => !/\/app\/initiatives\/\d+/.test(t.url)) ?? onApp[0] ?? null;
}

async function acquireTarget() {
  const existing = pickTarget(await listTargets(CDP_URL), APP_URL);
  if (existing !== null) {
    process.stdout.write(`tab   reusing ${existing.url}\n`);
    return existing;
  }
  const opened = await openTarget(CDP_URL, "about:blank");
  if (!opened?.webSocketDebuggerUrl) throw new Error("no webSocketDebuggerUrl in the /json/new reply");
  process.stdout.write("tab   opened a new one (none was on the app)\n");
  return opened;
}

async function acquireSession() {
  const target = await acquireTarget();
  return { target, session: await connect(target.webSocketDebuggerUrl) };
}

// ---------------------------------------------------------------------------

/**
 * The operator's "don't show this again" choices, set aside for the run:
 * `skipKey/1` in `tree/confirm_model.ts`, one per confirm class (a `.ts` this
 * Node cannot import).
 */
const SKIP_KEYS = ["cascade-complete", "completion-flip", "cascade-sort"].map(
  (confirmClass) => `doit:confirm-skip:${confirmClass}`,
);

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

  const { session } = await acquireSession();
  const stamp = Date.now();
  const results = [];
  let failed = false;
  let savedSkips = null;

  try {
    await session.send("Page.enable");
    await session.send("Runtime.enable");
    await session.send("Network.enable");
    await session.send("Emulation.setDeviceMetricsOverride", {
      ...VIEWPORT,
      deviceScaleFactor: 1,
      mobile: false,
    });

    await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives` });
    await waitFor(session, "return window.__doit_client_ready === true;", {
      timeoutMs: READY_TIMEOUT_MS,
      what: "the client to come up",
    });

    // Every confirm asks during the run; the operator's choices come back after.
    savedSkips = await evaluate(
      session,
      `
      const saved = {};
      for (const key of ${JSON.stringify(SKIP_KEYS)}) {
        saved[key] = localStorage.getItem(key);
        localStorage.removeItem(key);
      }
      return saved;
    `,
    );

    await withThrowaway({
      create: () => createThrowaway(session, stamp),
      onLeak: (throwaway, cause) => {
        process.stdout.write(`LEAK  "${throwaway.name}" could not be trashed: ${cause.message}\n`);
      },
      trash: async (throwaway) => {
        await session.send("Network.emulateNetworkConditions", FAST_LINK).catch(() => {});
        await trashThrowaway(session, throwaway, stamp);
        process.stdout.write(`note  trashed "${throwaway.name}"\n`);
      },
      run: async (throwaway) => {
        process.stdout.write(`note  created "${throwaway.name}"\n`);
        await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives/${throwaway.id}` });
        await waitFor(session, `return window.__doit_client_ready === true && document.getElementById("task-tree") !== null;`, {
          timeoutMs: READY_TIMEOUT_MS,
          what: "the tree to come up",
        });
        await evaluate(session, PAGE_HELPERS);
        await session.send("Network.emulateNetworkConditions", { ...FAST_LINK, latency: LINK_LATENCY_MS });

        const ctx = { session, appUrl: APP_URL, initiativeId: throwaway.id, ids: {} };
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
            const shot = await screenshot(session, `tree-${name.replace(/\W+/g, "-")}`);
            results.push({ name, status: "FAIL", ms: Date.now() - started, note: error.message, shot });
          }
        }
      },
    });
  } finally {
    await session.send("Network.emulateNetworkConditions", FAST_LINK).catch(() => {});
    if (savedSkips !== null) {
      await evaluate(
        session,
        `
        for (const [key, value] of Object.entries(${JSON.stringify(savedSkips)})) {
          if (value === null) localStorage.removeItem(key); else localStorage.setItem(key, value);
        }
        return true;
      `,
      ).catch(() => {});
    }
    await session.send("Network.disable").catch(() => {});
    // The tab stays open, on the index, for the next run to reuse.
    await session.send("Page.navigate", { url: `${APP_URL}/app/initiatives` }).catch(() => {});
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

// Only when run as the script — importing this file (the unit tests do) must
// not reach for a browser.
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
