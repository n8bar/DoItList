#!/usr/bin/env node
// The tree harness (m04.02 items 8.3, 8.4, 8.5): drive a REAL browser through the
// client's own tree at `/app/initiatives/:id` and report PASS/FAIL for add,
// edit, completion, the cascade confirm, the delete confirm and delete, undo
// and redo (7.3, 7.6), then
// reorder, reparent, the forbidden drop, the root and tail zones, the
// move-flip confirm and sort (7.4), then selection, the Details pane and its
// flyout, references, presence and the deep link (8.5). Drags are real mouse
// gestures over the row handles — press, glide past the threshold, release.
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
  mouseDown,
  mouseGlide,
  mouseMove,
  mouseUp,
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

/** The rows the move checks (7.4) drag around; seeded through the page's session. */
const MOVE_TITLES = {
  bravo: "Bravo",
  charlie: "Charlie",
  delta: "Delta",
  echo: "Echo",
  foxtrot: "Foxtrot",
};

/** Under the cascade-sort threshold nothing asks; one over it does. */
const CASCADE_SORT_BRANCHES = 11;

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
 * Delete from the Details pane asks first (item 7.6, §6.5): the delete confirm
 * opens at once with nothing sent; Cancel leaves the tree as it was; asked
 * again, Delete takes the row away before the reply.
 */
export async function checkDelete(ctx) {
  const { session } = ctx;
  const childId = ctx.ids.child;

  await selectRow(session, childId);
  await waitFor(session, `return document.getElementById("delete-task-btn") !== null;`, {
    timeoutMs: 5_000,
    what: "the Delete button",
  });

  const confirmOpen = `
    const dialog = document.getElementById("delete-confirm");
    return dialog !== null && dialog.open ? { title: dialog.querySelector("h2")?.textContent.trim() } : false;
  `;
  const before = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  await armStopwatch(session, "click", confirmOpen, { transient: true });
  await clickElement(session, "#delete-task-btn");
  const asked = await readStopwatch(session, "the delete confirm", { expectReply: false });
  if (asked.ackMs > ACK_BUDGET_MS) throw new Error(`the confirm took ${asked.ackMs}ms to open`);
  if (asked.detail.title !== "Delete task") throw new Error(`the confirm is titled "${asked.detail.title}"`);
  const noBox = await evaluate(session, `return document.getElementById("delete-confirm-dont-show") === null;`);
  if (!noBox) throw new Error('the delete confirm offers "don\'t show this again"; the workspace\'s does not');

  const held = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  if (held.sent !== before.sent) throw new Error("an operation was sent while the question was open");
  if (held.tree !== before.tree) throw new Error("the tree changed while the question was open");

  await clickElement(session, "#delete-confirm-cancel");
  await waitFor(session, `return document.getElementById("delete-confirm")?.open === false;`, {
    timeoutMs: 5_000,
    what: "the confirm to close",
  });
  // Nothing was queued, so there is nothing to wait for — but give a wrongly
  // sent operation the time it would need to show up.
  await new Promise((done) => setTimeout(done, LINK_LATENCY_MS));
  const after = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  if (after.sent !== before.sent) throw new Error("Cancel sent an operation");
  if (after.tree !== before.tree) throw new Error("Cancel changed the tree");
  const stillThere = await evaluate(session, `return __tree.rowEl(${childId}) !== null;`);
  if (!stillThere) throw new Error("Cancel took the row away");

  // Asked again; this time Delete. The row leaves on the click, not the reply.
  await armStopwatch(session, "click", confirmOpen, { transient: true });
  await clickElement(session, "#delete-task-btn");
  const askedAgain = await readStopwatch(session, "the delete confirm, again", { expectReply: false });
  if (askedAgain.ackMs > ACK_BUDGET_MS) throw new Error(`the second confirm took ${askedAgain.ackMs}ms to open`);

  await armStopwatch(session, "click", `return __tree.rowEl(${childId}) === null;`);
  await clickElement(session, "#delete-confirm-confirm");
  const ack = await readStopwatch(session, "the row to go");
  assertAcknowledged(ack, "the deleted row");

  const settled = await settle(session);
  const gone = await evaluate(session, `return __tree.rowEl(${childId}) === null;`);
  if (!gone) throw new Error("the row came back after the reply");
  const paneOpen = await evaluate(session, `return document.getElementById("task-field-title") !== null;`);
  if (paneOpen) throw new Error("the Details pane is still open on a deleted task");

  return `confirm open ${asked.ackMs}ms after the click, nothing sent, Cancel left the tree as it was; asked again, row gone ${ack.ackMs}ms after Delete, ${ack.replyMs - ack.ackMs}ms before the reply; settled with ${settled.note}`;
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

// ---------------------------------------------------------------------------
// Item 7.4: move, reorder, sort, and the drag bands. The tree after 7.3 is one
// row, "Alpha, renamed"; the first check seeds the rest through the page's
// session (one batch, `lid`s for the children) and every check after builds on
// what the last one left.
// ---------------------------------------------------------------------------

/**
 * Reorder: the last root row dragged to the "before" band of the second. The
 * root list reads in the new order before the reply, and stays that way.
 */
export async function checkReorder(ctx) {
  const { session } = ctx;
  await seedMoveRows(ctx);
  const { bravo, delta } = ctx.ids;

  const before = await evaluate(session, `return __tree.order(null);`);
  const expected = movedBefore(before, delta, bravo);

  const pointer = await beginDrag(session, delta);
  const paint = await dragOver(session, pointer, await bandPoint(session, bravo, "above"));
  if (paint.placeholder === null || paint.placeholder.next !== bravo || paint.placeholder.parent !== null) {
    throw new Error(`the placeholder is not above "Bravo": ${JSON.stringify(paint)}`);
  }

  await armStopwatch(session, "pointerup", `return ${sameOrder(null, expected)};`);
  await mouseUp(session, pointer);
  const ack = await readStopwatch(session, "the root list in its new order");
  assertAcknowledged(ack, "the reordered list");

  const settled = await settle(session);
  const after = await evaluate(session, `return __tree.order(null);`);
  if (!sameIds(after, expected)) throw new Error(`the root list settled as ${JSON.stringify(after)}, not ${JSON.stringify(expected)}`);
  await assertNothingPainted(session, "after the drop");

  return `${before.length} root rows; new order ${ack.ackMs}ms after release, ${ack.replyMs - ack.ackMs}ms before the reply; settled with ${settled.note}`;
}

/**
 * Reparent: a root row dropped on the "inside" band of a branch becomes its
 * first child, and the branch's roll-up is predicted at once (one done leaf
 * over three: 50% → 33%) with the bar marked recomputing until the number
 * comes back.
 */
export async function checkReparent(ctx) {
  const { session } = ctx;
  const { bravo, charlie, echo } = ctx.ids;

  // A done leaf inside the branch, so the roll-up has something to move.
  await completeLeaf(session, echo);
  const before = await evaluate(session, `return __tree.progress(${bravo});`);
  if (before !== "50") throw new Error(`"Bravo" reads ${before}% over one done leaf of two, not 50%`);

  const pointer = await beginDrag(session, charlie);
  const paint = await dragOver(session, pointer, await bandPoint(session, bravo, "center"));
  if (paint.target !== bravo) throw new Error(`"Bravo" is not ringed as the target: ${JSON.stringify(paint)}`);

  await armStopwatch(
    session,
    "pointerup",
    `
    const order = __tree.order(${bravo});
    if (order === null || order[0] !== ${charlie}) return false;
    const parent = __tree.rowEl(${bravo});
    return { progress: parent.dataset.taskProgress, recomputing: parent.classList.contains("is-recomputing") };
  `,
  );
  await mouseUp(session, pointer);
  const ack = await readStopwatch(session, `"Charlie" as the first child of "Bravo"`);
  assertAcknowledged(ack, "the reparented row");
  if (ack.detail.progress !== "33") throw new Error(`"Bravo" predicted ${ack.detail.progress}% over one done leaf of three, not 33%`);
  if (!ack.detail.recomputing) throw new Error(`"Bravo"'s bar was not marked recomputing`);

  const settled = await settle(session);
  const after = await evaluate(
    session,
    `return { order: __tree.order(${bravo}), progress: __tree.progress(${bravo}), depth: document.getElementById("task-${charlie}")?.dataset.depth };`,
  );
  if (after.order[0] !== charlie) throw new Error(`"Charlie" settled at ${JSON.stringify(after.order)} under "Bravo"`);
  if (after.progress !== "33") throw new Error(`"Bravo" settled at ${after.progress}%`);
  if (after.depth !== "1") throw new Error(`"Charlie" settled at depth ${after.depth}, not 1`);

  return `first child ${ack.ackMs}ms after release, ${ack.replyMs - ack.ackMs}ms before the reply; "Bravo" ${before}% → ${after.progress}%, settled with ${settled.note}`;
}

/**
 * Forbidden: a branch dragged over its own child paints no target at all (the
 * source subtree is not a place to land), and a child dragged onto the
 * "inside" band of its own parent paints `drop-forbidden`. Neither release
 * sends anything or moves anything.
 */
export async function checkForbiddenDrop(ctx) {
  const { session } = ctx;
  const { bravo, echo } = ctx.ids;

  const before = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);

  // A parent over its own descendant.
  let pointer = await beginDrag(session, bravo);
  let paint = await dragOver(session, pointer, await bandPoint(session, echo, "center"));
  if (paint.target !== null || paint.forbidden !== null || paint.placeholder !== null || paint.zone !== null || paint.tail !== null) {
    throw new Error(`a drag over the source's own child painted a target: ${JSON.stringify(paint)}`);
  }
  await mouseUp(session, pointer);
  await assertNothingSent(session, before, "a release over the source's own child");

  // A child onto its own parent's "inside" band.
  pointer = await beginDrag(session, echo);
  paint = await dragOver(session, pointer, await bandPoint(session, bravo, "center"));
  if (paint.forbidden !== bravo) throw new Error(`"Bravo" is not marked forbidden for its own child: ${JSON.stringify(paint)}`);
  if (paint.cursor !== "not-allowed") throw new Error(`the cursor reads "${paint.cursor}", not not-allowed`);
  await mouseUp(session, pointer);
  await assertNothingSent(session, before, "a release on the source's own parent");
  await assertNothingPainted(session, "after the forbidden release");

  return `descendant: nothing painted, nothing sent; own parent: drop-forbidden with a not-allowed cursor, nothing sent; tree unchanged`;
}

/**
 * The root zone and a branch's tail zone, both mounted only while a drag is
 * on: a child dropped in the bottom root zone lands last at the root; a root
 * row dropped on a branch's tail lands as its last child.
 */
export async function checkRootAndTailZones(ctx) {
  const { session } = ctx;
  const { task: alpha, bravo, foxtrot } = ctx.ids;

  // Out to the root's end.
  let pointer = await beginDrag(session, foxtrot);
  let paint = await dragOver(session, pointer, await zonePoint(session, `#task-tree > li.drop-root-zone[data-zone="bottom"]`, "the bottom root zone"));
  if (paint.zone !== "bottom") throw new Error(`the bottom root zone is not lit: ${JSON.stringify(paint)}`);
  await armStopwatch(session, "pointerup", `const o = __tree.order(null); return o !== null && o[o.length - 1] === ${foxtrot};`);
  await mouseUp(session, pointer);
  let ack = await readStopwatch(session, `"Foxtrot" last at the root`);
  assertAcknowledged(ack, "the row moved to the root's end");
  let settled = await settle(session);
  const rootAfter = await evaluate(session, `return { order: __tree.order(null), depth: document.getElementById("task-${foxtrot}")?.dataset.depth };`);
  if (rootAfter.order[rootAfter.order.length - 1] !== foxtrot) throw new Error(`"Foxtrot" settled at ${JSON.stringify(rootAfter.order)}`);
  if (rootAfter.depth !== "0") throw new Error(`"Foxtrot" settled at depth ${rootAfter.depth}, not 0`);
  const zoneNote = `root zone: last ${ack.ackMs}ms after release, ${ack.replyMs - ack.ackMs}ms before the reply, ${settled.note}`;

  // In, as the branch's last child.
  pointer = await beginDrag(session, alpha);
  paint = await dragOver(session, pointer, await zonePoint(session, `li.drop-tail[data-branch="${bravo}"]`, `"Bravo"'s tail zone`));
  if (paint.tail !== bravo) throw new Error(`"Bravo"'s tail zone is not lit: ${JSON.stringify(paint)}`);
  await armStopwatch(session, "pointerup", `const o = __tree.order(${bravo}); return o !== null && o[o.length - 1] === ${alpha};`);
  await mouseUp(session, pointer);
  ack = await readStopwatch(session, `"Alpha, renamed" last under "Bravo"`);
  assertAcknowledged(ack, "the row appended to the branch");
  settled = await settle(session);
  const tailAfter = await evaluate(session, `return { order: __tree.order(${bravo}), depth: document.getElementById("task-${alpha}")?.dataset.depth };`);
  if (tailAfter.order[tailAfter.order.length - 1] !== alpha) throw new Error(`"Alpha, renamed" settled at ${JSON.stringify(tailAfter.order)} under "Bravo"`);
  if (tailAfter.depth !== "1") throw new Error(`"Alpha, renamed" settled at depth ${tailAfter.depth}, not 1`);
  await assertNothingPainted(session, "after the tail drop");

  return `${zoneNote}; tail zone: last child ${ack.ackMs}ms after release, ${ack.replyMs - ack.ackMs}ms before the reply, ${settled.note}`;
}

/**
 * The move-flip confirm (`completion-flip`): an open task dropped inside a
 * done leaf would reopen it, so the question opens at once and nothing is
 * sent. Cancel leaves everything as it was; asked again, Proceed moves the
 * row and reopens the parent before the reply.
 */
export async function checkMoveFlipConfirm(ctx) {
  const { session } = ctx;
  const { delta, foxtrot } = ctx.ids;

  // A done leaf at the root: the destination whose state the move would flip.
  await completeLeaf(session, delta);

  const dragToDelta = async () => {
    const pointer = await beginDrag(session, foxtrot);
    const paint = await dragOver(session, pointer, await bandPoint(session, delta, "center"));
    if (paint.target !== delta) throw new Error(`"Delta" is not ringed as the target: ${JSON.stringify(paint)}`);
    return pointer;
  };
  const dialogOpen = `
    const dialog = document.getElementById("move-flip-confirm");
    return dialog !== null && dialog.open ? { title: dialog.querySelector("h2")?.textContent.trim() } : false;
  `;

  // Ask, then Cancel.
  const before = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  let pointer = await dragToDelta();
  await armStopwatch(session, "pointerup", dialogOpen, { transient: true });
  await mouseUp(session, pointer);
  const asked = await readStopwatch(session, "the move-flip confirm", { expectReply: false });
  if (asked.ackMs > ACK_BUDGET_MS) throw new Error(`the confirm took ${asked.ackMs}ms to open`);
  if (asked.detail.title !== "Confirm completion change") throw new Error(`the confirm is titled "${asked.detail.title}"`);
  const held = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  if (held.sent !== before.sent) throw new Error("an operation was sent while the question was open");
  if (held.tree !== before.tree) throw new Error("the tree changed while the question was open");
  await clickElement(session, "#move-flip-confirm-cancel");
  await waitFor(session, `return document.getElementById("move-flip-confirm")?.open === false;`, { timeoutMs: 5_000, what: "the confirm to close" });
  await assertNothingSent(session, before, "Cancel");

  // Ask again, then Proceed.
  pointer = await dragToDelta();
  await armStopwatch(session, "pointerup", dialogOpen, { transient: true });
  await mouseUp(session, pointer);
  const askedAgain = await readStopwatch(session, "the move-flip confirm, again", { expectReply: false });
  if (askedAgain.ackMs > ACK_BUDGET_MS) throw new Error(`the second confirm took ${askedAgain.ackMs}ms to open`);

  await armStopwatch(
    session,
    "click",
    `
    const order = __tree.order(${delta});
    if (order === null || order[0] !== ${foxtrot}) return false;
    return { deltaDone: __tree.rowEl(${delta})?.dataset.done === "true" };
  `,
  );
  await clickElement(session, "#move-flip-confirm-confirm");
  const ack = await readStopwatch(session, `"Foxtrot" under "Delta"`);
  assertAcknowledged(ack, "the confirmed move");
  if (ack.detail.deltaDone) throw new Error(`"Delta" still read done once its open child landed`);

  const settled = await settle(session);
  const after = await evaluate(
    session,
    `return { order: __tree.order(${delta}), deltaDone: __tree.rowEl(${delta})?.dataset.done === "true", progress: __tree.progress(${delta}) };`,
  );
  if (after.order[0] !== foxtrot) throw new Error(`"Foxtrot" settled at ${JSON.stringify(after.order)} under "Delta"`);
  if (after.deltaDone) throw new Error(`"Delta" settled as done over an open child`);

  return `confirm open ${asked.ackMs}ms after release, nothing sent, Cancel left the tree as it was; asked again, moved ${ack.ackMs}ms after Proceed, ${ack.replyMs - ack.ackMs}ms before the reply; "Delta" reopened at ${after.progress}%, settled with ${settled.note}`;
}

/**
 * Sort: Alphabetical set on a branch from the pane reorders its children
 * before the reply and the list carries the mode. Make descendants inherit on
 * a branch over the cascade threshold asks first; Cancel sends nothing and
 * leaves every child where it was.
 */
export async function checkSort(ctx) {
  const { session } = ctx;
  const { bravo, delta } = ctx.ids;

  // Alphabetical on "Bravo": Charlie, Echo, Alpha → Alpha, Charlie, Echo.
  await selectRow(session, bravo);
  await waitFor(session, `return document.getElementById("sort-mode-task") !== null;`, { timeoutMs: 5_000, what: "the Sort control" });
  const before = await evaluate(session, `return __tree.order(${bravo}).map((id) => [id, __tree.title(id)]);`);
  const expected = [...before].sort(([a, ta], [b, tb]) => (ta.toLowerCase() < tb.toLowerCase() ? -1 : ta.toLowerCase() > tb.toLowerCase() ? 1 : a - b)).map(([id]) => id);
  if (sameIds(before.map(([id]) => id), expected)) throw new Error(`"Bravo"'s children already read alphabetical: ${JSON.stringify(before)}`);

  await armStopwatch(
    session,
    "change",
    `
    if (!${sameOrder(bravo, expected)}) return false;
    return { mode: document.getElementById("children-${bravo}")?.dataset.sortMode };
  `,
  );
  // The pane's <select>: a native popup CDP cannot drive, so the choice is
  // made on the element and announced with the change event React listens for.
  await evaluate(
    session,
    `
    const select = document.getElementById("sort-mode-task");
    select.focus();
    select.value = "alphabetical";
    select.dispatchEvent(new Event("change", { bubbles: true }));
    return true;
  `,
  );
  const ack = await readStopwatch(session, `"Bravo"'s children in alphabetical order`);
  assertAcknowledged(ack, "the sorted children");
  if (ack.detail.mode !== "alphabetical") throw new Error(`the list carries sort mode "${ack.detail.mode}"`);

  const settled = await settle(session);
  const after = await evaluate(session, `return { order: __tree.order(${bravo}), mode: document.getElementById("children-${bravo}")?.dataset.sortMode, field: document.getElementById("sort-mode-task")?.value };`);
  if (!sameIds(after.order, expected)) throw new Error(`"Bravo"'s children settled as ${JSON.stringify(after.order)}, not ${JSON.stringify(expected)}`);
  if (after.mode !== "alphabetical" || after.field !== "alphabetical") throw new Error(`settled with list mode "${after.mode}" and field "${after.field}"`);
  const sortNote = `alphabetical: reordered ${ack.ackMs}ms after the change, ${ack.replyMs - ack.ackMs}ms before the reply, ${settled.note}`;

  // Cascade on "Delta", once it has more descendant branches than the threshold.
  await seedCascadeBranches(ctx);
  await selectRow(session, delta);
  await waitFor(session, `return document.querySelector('[data-cascade-sort][data-task-id="${delta}"]') !== null;`, { timeoutMs: 5_000, what: "the Make descendants inherit button" });
  const held = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent, modes: __tree.sortModes(${delta}) };`);

  await armStopwatch(
    session,
    "click",
    `
    const dialog = document.getElementById("cascade-sort-confirm");
    return dialog !== null && dialog.open ? { title: dialog.querySelector("h2")?.textContent.trim() } : false;
  `,
    { transient: true },
  );
  await clickElement(session, `[data-cascade-sort][data-task-id="${delta}"]`);
  const asked = await readStopwatch(session, "the cascade-sort confirm", { expectReply: false });
  if (asked.ackMs > ACK_BUDGET_MS) throw new Error(`the confirm took ${asked.ackMs}ms to open`);
  if (asked.detail.title !== "Large branch reorg") throw new Error(`the confirm is titled "${asked.detail.title}"`);
  const open = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  if (open.sent !== held.sent) throw new Error("an operation was sent while the question was open");
  if (open.tree !== held.tree) throw new Error("the tree changed while the question was open");

  await clickElement(session, "#cascade-sort-confirm-cancel");
  await waitFor(session, `return document.getElementById("cascade-sort-confirm")?.open === false;`, { timeoutMs: 5_000, what: "the confirm to close" });
  await assertNothingSent(session, held, "Cancel");
  const modes = await evaluate(session, `return __tree.sortModes(${delta});`);
  if (modes !== held.modes) throw new Error(`Cancel changed a descendant's sort: ${modes}`);

  return `${sortNote}; cascade over ${CASCADE_SORT_BRANCHES} branches: confirm open ${asked.ackMs}ms after the click, nothing sent, Cancel left every child and its sort as it was`;
}

// ---------------------------------------------------------------------------
// Item 8.5: selection, panes, references, presence, and deep links. Every one
// of these is view state (§6.5): the DOM answers at the click and no fetch
// goes out — the one thing that does go out is the `select` presence push on
// the socket (item 3.4.1), which is not waited on. The markers asserted are
// the workspace's own: `li[data-selected]`, `#details-rail[data-open]`,
// `#pane-backdrop`, `[data-close-task]` / `[data-close-panel]`, `a.doit-ref`
// / `span.doit-ref-dead`, `[data-presence-slot]`, and `?task=<id>`.
// ---------------------------------------------------------------------------

const PHONE = { width: 390, height: 844 };
/** Wide enough for the flyout to leave the backdrop showing beside it (`sm:w-96`). */
const TABLET = { width: 768, height: 1024 };
/** A `%<id>` no task will ever have: the dead-reference case. */
const DEAD_REF_ID = 999_999_999;
/** The other member the presence check plays, as `selection_meta/2` would name them. */
const PEER = {
  user_id: -4242,
  name: "CDP peer",
  initials: "CP",
  bg: "linear-gradient(135deg, #f59e0b, #ef4444)",
  fg: "#ffffff",
};

/**
 * Selection is local: a click on a row selects it at once, a click on another
 * moves it, a click on the selected row again clears it (the workspace's
 * toggle), and Escape clears it. Nothing is fetched for any of it.
 */
export async function checkSelection(ctx) {
  const { session } = ctx;
  const { charlie, echo } = ctx.ids;

  const before = await evaluate(session, `return __ops.log.length;`);
  await pressKey(session, "Escape");
  await waitFor(session, `return __tree.selected() === null;`, { timeoutMs: 2_000, what: "nothing selected to begin with" });

  await armStopwatch(session, "click", `return __tree.selected() === ${charlie};`);
  await clickElement(session, titleOf(charlie));
  const picked = await readStopwatch(session, `"Charlie" selected`, { expectReply: false });
  assertAcknowledged(picked, "the selected row");

  await armStopwatch(
    session,
    "click",
    `return __tree.selected() === ${echo} && document.querySelector("#task-${charlie}[data-selected]") === null;`,
  );
  await clickElement(session, titleOf(echo));
  const moved = await readStopwatch(session, `the selection on "Echo"`, { expectReply: false });
  assertAcknowledged(moved, "the moved selection");

  await armStopwatch(session, "click", `return __tree.selected() === null;`);
  await clickElement(session, titleOf(echo));
  const toggled = await readStopwatch(session, "the selection cleared by a second click", { expectReply: false });
  assertAcknowledged(toggled, "the cleared selection");

  await clickElement(session, titleOf(charlie));
  await waitFor(session, `return __tree.selected() === ${charlie};`, { timeoutMs: 2_000, what: `"Charlie" selected again` });
  await armStopwatch(session, "keydown", `return __tree.selected() === null;`);
  await pressKey(session, "Escape");
  const escaped = await readStopwatch(session, "the selection cleared by Escape", { expectReply: false });
  assertAcknowledged(escaped, "the Escape");

  await assertNothingFetched(session, before, "selecting and deselecting");
  return `selected ${picked.ackMs}ms, moved ${moved.ackMs}ms, cleared by a second click ${toggled.ackMs}ms and by Escape ${escaped.ackMs}ms after the event; nothing fetched`;
}

/**
 * At desktop width the Details pane opens in its slot with the selection:
 * `#details-rail[data-open="true"]`, sticky beside the tree, the backdrop
 * hidden. Its Close (`[data-close-task]`) deselects and the slot goes away.
 */
export async function checkPaneDesktop(ctx) {
  const { session } = ctx;
  const { charlie } = ctx.ids;

  const before = await evaluate(session, `return __ops.log.length;`);
  await armStopwatch(session, "click", `return __tree.pane(${JSON.stringify(MOVE_TITLES.charlie)});`);
  await clickElement(session, titleOf(charlie));
  const opened = await readStopwatch(session, "the Details pane", { expectReply: false });
  assertAcknowledged(opened, "the open pane");
  const pane = opened.detail;
  if (pane.position !== "sticky") throw new Error(`the pane is "${pane.position}" at desktop width, not sticky in its slot`);
  if (pane.backdrop !== "none") throw new Error(`the backdrop is "${pane.backdrop}" at desktop width, not hidden`);
  if (!pane.inSlot) throw new Error("the pane is not in the frame's slot beside the tree");
  if (!pane.closeVisible) throw new Error("the pane's Close is not on screen at desktop width");

  await armStopwatch(session, "click", `return __tree.paneClosed() && __tree.selected() === null;`);
  await clickElement(session, "#details-rail [data-close-task]");
  const closed = await readStopwatch(session, "the pane to close", { expectReply: false });
  assertAcknowledged(closed, "the closed pane");

  await assertNothingFetched(session, before, "opening and closing the pane");
  return `open ${opened.ackMs}ms after the click (sticky, backdrop hidden, field reads "${pane.value}"); closed and deselected ${closed.ackMs}ms after Close; nothing fetched`;
}

/**
 * Below `lg:` the pane is the workspace's flyout (item 7.1): fixed over a
 * backdrop, with the rail's own X. The X closes and deselects at phone width;
 * the backdrop does the same at tablet width, where it shows beside the rail.
 */
export async function checkPaneFlyout(ctx) {
  const { session } = ctx;
  const { charlie } = ctx.ids;
  const title = MOVE_TITLES.charlie;

  const before = await evaluate(session, `return __ops.log.length;`);
  try {
    await setViewport(session, PHONE, true);
    await armStopwatch(session, "click", `return __tree.pane(${JSON.stringify(title)});`);
    await clickElement(session, titleOf(charlie));
    const opened = await readStopwatch(session, "the flyout", { expectReply: false });
    assertAcknowledged(opened, "the open flyout");
    const pane = opened.detail;
    if (pane.position !== "fixed") throw new Error(`the pane is "${pane.position}" at phone width, not a fixed flyout`);
    if (pane.backdrop !== "block") throw new Error(`the backdrop is "${pane.backdrop}" at phone width, not shown`);
    if (!pane.railCloseVisible) throw new Error("the rail's X is not on screen at phone width");

    await armStopwatch(session, "click", `return __tree.paneClosed() && __tree.selected() === null;`);
    await clickElement(session, "#details-rail button[data-close-panel]");
    const closedByX = await readStopwatch(session, "the flyout to close", { expectReply: false });
    assertAcknowledged(closedByX, "the flyout closed by its X");

    await setViewport(session, TABLET, true);
    await clickElement(session, titleOf(charlie));
    await waitFor(session, `return __tree.pane(${JSON.stringify(title)}) !== false;`, { timeoutMs: 2_000, what: "the flyout at tablet width" });
    const at = await evaluate(
      session,
      `
      const p = { x: 40, y: 300 };
      const el = document.elementFromPoint(p.x, p.y);
      return el?.id === "pane-backdrop" ? p : { hit: el?.tagName + (el?.id ? "#" + el.id : "") };
    `,
    );
    if (at.hit !== undefined) throw new Error(`the backdrop is not showing beside the rail at tablet width (found ${at.hit})`);
    await armStopwatch(session, "click", `return __tree.paneClosed() && __tree.selected() === null;`);
    await clickAt(session, at);
    const closedByBackdrop = await readStopwatch(session, "the flyout to close from the backdrop", { expectReply: false });
    assertAcknowledged(closedByBackdrop, "the flyout closed by its backdrop");

    await assertNothingFetched(session, before, "the flyout");
    return `phone: flyout ${opened.ackMs}ms after the tap (fixed, backdrop shown), closed by the rail's X in ${closedByX.ackMs}ms; tablet: closed by the backdrop in ${closedByBackdrop.ackMs}ms; nothing fetched`;
  } finally {
    await setViewport(session, VIEWPORT, false);
  }
}

/**
 * A `%<id>` reference in a title renders as the workspace's `buildRefNode`
 * does — a live one as `a.doit-ref` reading the target's label, a dead one as
 * `span.doit-ref-dead` reading "%?" — and clicking the link reveals the target:
 * its collapsed branch opens, it is selected (the referring row is not) and
 * scrolled into view, with nothing fetched.
 */
export async function checkReferences(ctx) {
  const { session, initiativeId } = ctx;
  const { bravo, charlie } = ctx.ids;

  // Numbering on, so a live reference reads as a label rather than "↗". The
  // Initiative channel ignores `initiative_updated` on purpose (it says so),
  // so a style set from outside the tab reaches it only by a fresh read.
  await pageOperation(session, `cdp-tree-${ctx.stamp}-numbering`, {
    op: "update",
    type: "initiative",
    id: initiativeId,
    data: { index_style: "numerical" },
  });
  await reopenTree(ctx);
  await waitFor(session, `return document.querySelector("#task-${charlie} > [data-task-row] [data-task-index]") !== null;`, {
    timeoutMs: 5_000,
    what: "the rows to be numbered",
  });

  const result = await pageOperation(session, `cdp-tree-${ctx.stamp}-seed-ref`, {
    op: "add",
    type: "task",
    data: { initiative_id: initiativeId, title: `See %<${charlie}> and %<${DEAD_REF_ID}>` },
  });
  const referrer = result?.data?.id;
  if (typeof referrer !== "number") throw new Error(`the referring task was not added: ${JSON.stringify(result)}`);
  ctx.ids.referrer = referrer;
  await waitForRows(session, [referrer], "the referring row");

  const rendered = await evaluate(
    session,
    `
    const title = document.querySelector("#task-${referrer} > [data-task-row] [data-task-title]");
    return {
      links: [...title.querySelectorAll("a.doit-ref[data-task-id]")].map((a) => ({ id: Number(a.dataset.taskId), text: a.textContent.trim(), role: a.getAttribute("role") })),
      dead: [...title.querySelectorAll("span.doit-ref-dead[data-task-id]")].map((s) => ({ id: Number(s.dataset.taskId), text: s.textContent.trim(), title: s.title })),
      raw: /%<\\d+>/.test(title.textContent),
      label: document.querySelector("#task-${charlie} > [data-task-row] [data-copy-index]")?.dataset.copyIndex ?? null,
    };
  `,
  );
  if (rendered.raw) throw new Error("a raw %<id> token is showing in the title");
  const [link] = rendered.links;
  if (rendered.links.length !== 1 || link.id !== charlie || link.role !== "link") {
    throw new Error(`the live reference did not render as one a.doit-ref to "Charlie": ${JSON.stringify(rendered.links)}`);
  }
  if (rendered.label === null || link.text !== rendered.label) {
    throw new Error(`the live reference reads "${link.text}", not "Charlie"'s label "${rendered.label}"`);
  }
  const [dead] = rendered.dead;
  if (rendered.dead.length !== 1 || dead.id !== DEAD_REF_ID || dead.text !== "%?" || dead.title !== "Referenced task not found") {
    throw new Error(`the dead reference did not render as the workspace's "%?": ${JSON.stringify(rendered.dead)}`);
  }

  // Bury the target, then follow the link to it.
  await collapseBranch(session, bravo);
  const before = await evaluate(session, `return __ops.log.length;`);
  await armStopwatch(
    session,
    "click",
    `
    if (__tree.selected() !== ${charlie}) return false;
    if (document.getElementById("children-${bravo}")?.classList.contains("collapsed-peek")) return false;
    return { referrerSelected: document.querySelector("#task-${referrer}[data-selected]") !== null };
  `,
  );
  await clickElement(session, `#task-${referrer} > [data-task-row] a.doit-ref[data-task-id="${charlie}"]`);
  const ack = await readStopwatch(session, `"Charlie" revealed by its reference`, { expectReply: false });
  assertAcknowledged(ack, "the revealed target");
  if (ack.detail.referrerSelected) throw new Error("the referring row was selected too");
  await waitFor(session, `return __tree.inView(${charlie});`, { timeoutMs: 2_000, everyMs: 10, what: `"Charlie" scrolled into view` });
  await assertNothingFetched(session, before, "following a reference");

  return `live ref reads "${link.text}", dead ref reads "%?"; click opened "Bravo", selected "Charlie" ${ack.ackMs}ms after it, scrolled into view; nothing fetched`;
}

/**
 * Presence (item 3.4): another member's selection is a badge on the row, and
 * it goes when they leave. Two halves, both through the page's own socket:
 *
 *   * the server's half — a second window of this account joins the
 *     Initiative's topic and selects "Charlie"; the page's socket receives the
 *     `presence_diff` the server broadcast for it (and its leave). Its own
 *     windows paint no badge, by design (`selectionsOf` skips self);
 *   * the client's half — another member's `presence_diff` (a join on
 *     "Charlie", a move to "Echo", a leave) is delivered on the page's socket
 *     as a message and the badge follows it at once, with nothing fetched.
 *
 * A second signed-in browser is the only way to see both halves as one event.
 */
export async function checkPresence(ctx) {
  const { session, initiativeId } = ctx;
  const { charlie, echo } = ctx.ids;
  const topic = `initiative:${initiativeId}`;

  const { identifier } = await session.send("Page.addScriptToEvaluateOnNewDocument", { source: WS_HOOK });
  try {
    await reopenTree(ctx);
    const socket = await waitFor(session, `return __ws.sockets.find((s) => s.readyState === 1)?.url ?? null;`, {
      timeoutMs: 10_000,
      what: "the page's own socket to be open",
    });
    if (!/\/socket\/websocket/.test(socket)) throw new Error(`the page's socket is not the WebSocket transport: ${socket}`);

    // The server's half.
    const me = await evaluate(
      session,
      `return (async () => (await (await fetch("/app/api/session", { headers: { accept: "application/json" }, credentials: "same-origin" })).json()).data?.user?.id ?? null)();`,
    );
    if (typeof me !== "number") throw new Error("the session read did not name the signed-in user");
    const peerJoined = await evaluate(session, secondWindow(topic, charlie));
    if (!peerJoined.ok) throw new Error(`the second window could not join: ${peerJoined.why}`);
    const joinFrame = `return __ws.diffs(${JSON.stringify(topic)}).some((d) => (d.joins?.[${JSON.stringify(String(me))}]?.metas ?? []).some((m) => m.task_id === ${charlie}));`;
    await waitFor(session, joinFrame, { timeoutMs: 5_000, everyMs: 20, what: "the server's presence_diff for the second window's selection" });
    const ownBadge = await evaluate(session, `return document.querySelector('[data-presence-slot="${charlie}"] > span') !== null;`);
    if (ownBadge) throw new Error("the page painted a badge for its own account's other window");
    await evaluate(session, `__ws.second?.close(); __ws.second = null; return true;`);
    const leaveFrame = `return __ws.diffs(${JSON.stringify(topic)}).some((d) => (d.leaves?.[${JSON.stringify(String(me))}]?.metas ?? []).some((m) => m.task_id === ${charlie}));`;
    await waitFor(session, leaveFrame, { timeoutMs: 5_000, everyMs: 20, what: "the server's presence_diff for the second window leaving" });

    // The client's half.
    const before = await evaluate(session, `return __ops.log.length;`);
    const badgeOn = (id) => `
      const badge = document.querySelector('[data-presence-slot="${id}"] > span');
      return badge === null ? false : { initials: badge.textContent.trim(), title: badge.title };
    `;
    const meta = (taskId, ref) => ({ ...PEER, task_id: taskId, phx_ref: ref });
    const diff = (joins, leaves) => ({
      joins: joins === null ? {} : { [PEER.user_id]: { metas: [joins] } },
      leaves: leaves === null ? {} : { [PEER.user_id]: { metas: [leaves] } },
    });

    await armStopwatch(session, "cdp-presence", badgeOn(charlie));
    await injectDiff(session, topic, diff(meta(charlie, "cdp-peer-1"), null));
    const joined = await readStopwatch(session, `the peer's badge on "Charlie"`, { expectReply: false });
    assertAcknowledged(joined, "the peer's badge");
    if (joined.detail.initials !== PEER.initials || joined.detail.title !== `${PEER.name} has this task selected`) {
      throw new Error(`the badge reads ${JSON.stringify(joined.detail)}`);
    }

    await armStopwatch(session, "cdp-presence", `if (document.querySelector('[data-presence-slot="${charlie}"] > span') !== null) return false; ${badgeOn(echo)}`);
    await injectDiff(session, topic, diff(meta(echo, "cdp-peer-2"), meta(charlie, "cdp-peer-1")));
    const moved = await readStopwatch(session, `the peer's badge moved to "Echo"`, { expectReply: false });
    assertAcknowledged(moved, "the moved badge");

    await armStopwatch(session, "cdp-presence", `return document.querySelector('[data-presence-slot="${echo}"] > span') === null;`);
    await injectDiff(session, topic, diff(null, meta(echo, "cdp-peer-2")));
    const left = await readStopwatch(session, "the peer's badge to go", { expectReply: false });
    assertAcknowledged(left, "the cleared badge");

    await assertNothingFetched(session, before, "presence");
    return `server: a second window's select and leave came back as presence_diffs, no badge for self; client: peer's badge on ${joined.ackMs}ms after the diff, moved in ${moved.ackMs}ms, gone in ${left.ackMs}ms; nothing fetched`;
  } finally {
    await evaluate(session, `__ws?.second?.close(); return true;`).catch(() => {});
    await session.send("Page.removeScriptToEvaluateOnNewDocument", { identifier }).catch(() => {});
  }
}

/**
 * A `?task=<id>` link (the workspace's `honor_task_param/2`): arriving on it
 * opens the collapsed branch the task is in, selects it, scrolls it into view
 * and opens the pane — before anything is fetched beyond the tree itself. The
 * address bar then follows the selection, and clears with it.
 */
export async function checkDeepLink(ctx) {
  const { session } = ctx;
  const { bravo, charlie, echo } = ctx.ids;
  const title = MOVE_TITLES.charlie;

  await pressKey(session, "Escape");
  await waitFor(session, `return __tree.selected() === null;`, { timeoutMs: 2_000, what: "nothing selected before the link" });
  await collapseBranch(session, bravo);

  const arrival = await reopenTree(ctx, `?task=${charlie}`);
  const revealed = await waitFor(
    session,
    `
    if (__tree.selected() !== ${charlie}) return null;
    if (document.getElementById("children-${bravo}")?.classList.contains("collapsed-peek")) return null;
    return { at: performance.now() };
  `,
    { timeoutMs: 5_000, everyMs: 5, what: `"Charlie" revealed by the link` },
  );
  const sinceTree = Math.round(revealed.at - arrival.at);
  if (arrival.selected !== charlie && sinceTree > ACK_BUDGET_MS) {
    throw new Error(`the tree was up ${sinceTree}ms before the link's task was selected`);
  }
  await waitFor(session, `return __tree.inView(${charlie}) && __tree.pane(${JSON.stringify(title)}) !== false;`, {
    timeoutMs: 2_000,
    everyMs: 10,
    what: `"Charlie" in view with its pane open`,
  });
  const search = await evaluate(session, `return window.location.search;`);
  if (search !== `?task=${charlie}`) throw new Error(`the address bar reads "${search}" after arrival`);

  // The parameter follows the selection, and goes with it.
  const before = await evaluate(session, `return __ops.log.length;`);
  await clickElement(session, titleOf(echo));
  const followed = await waitFor(session, `return window.location.search === "?task=${echo}" ? window.location.search : null;`, {
    timeoutMs: 2_000,
    everyMs: 10,
    what: "the address bar to follow the selection",
  });
  await pressKey(session, "Escape");
  await waitFor(session, `return __tree.selected() === null && window.location.search === "";`, {
    timeoutMs: 2_000,
    everyMs: 10,
    what: "the address bar to clear with the selection",
  });
  await assertNothingFetched(session, before, "the address bar following the selection");

  return `arrived with "Bravo" open, "Charlie" selected ${arrival.selected === charlie ? "in the tree's first paint" : `${sinceTree}ms after the tree`}, in view, pane open; address bar followed to "${followed}" and cleared with Escape; nothing fetched`;
}

/** The title element of row `id`, for a selecting click. */
function titleOf(id) {
  return `#task-${id} > [data-task-row] [data-task-title]`;
}

/** A click at a viewport point: the backdrop has no element centre worth aiming at. */
async function clickAt(session, at) {
  await mouseMove(session, at);
  await mouseDown(session, at);
  await mouseUp(session, at);
}

async function setViewport(session, { width, height }, mobile) {
  await session.send("Emulation.setDeviceMetricsOverride", { width, height, deviceScaleFactor: 1, mobile });
}

/** Collapses branch `id` through its own chevron and waits for the peek. */
async function collapseBranch(session, id) {
  const closed = await evaluate(session, `return document.getElementById("children-${id}")?.classList.contains("collapsed-peek") ?? null;`);
  if (closed === null) throw new Error(`branch #${id} has no children list`);
  if (closed) return;
  await clickElement(session, `#collapse-${id}`);
  await waitFor(session, `return document.getElementById("children-${id}")?.classList.contains("collapsed-peek") === true;`, {
    timeoutMs: 2_000,
    what: `branch #${id} to collapse`,
  });
}

/** View state costs no fetch at all: not an operation, not a read. */
async function assertNothingFetched(session, before, what) {
  const after = await evaluate(session, `return { count: __ops.log.length, since: __ops.log.slice(${before}).map((f) => f.method + " " + f.url.replace(/^.*\\/app\\/api/, "")) };`);
  if (after.count !== before) throw new Error(`${what} fetched: ${after.since.join(", ")}`);
}

/**
 * Navigates the tab to the throwaway again (with `search`, e.g. a deep link)
 * on a fast link, waits for the tree, re-installs the page helpers and puts
 * the run's latency back. Returns what the tree's first sighting held.
 */
async function reopenTree(ctx, search = "") {
  const { session } = ctx;
  await session.send("Network.emulateNetworkConditions", FAST_LINK);
  await evaluate(session, `window.__cdp_leaving = true; return true;`);
  await session.send("Page.navigate", { url: `${ctx.appUrl}/app/initiatives/${ctx.initiativeId}${search}` });
  const arrival = await waitFor(
    session,
    `
    if (window.__cdp_leaving === true) return null;
    if (window.__doit_client_ready !== true || document.getElementById("task-tree") === null) return null;
    const li = document.querySelector("#task-tree li[data-selected]");
    return { at: performance.now(), selected: li === null ? null : Number(li.dataset.taskId) };
  `,
    { timeoutMs: READY_TIMEOUT_MS, everyMs: 5, what: "the tree to come back up" },
  );
  await evaluate(session, PAGE_HELPERS);
  await session.send("Network.emulateNetworkConditions", { ...FAST_LINK, latency: LINK_LATENCY_MS });
  return arrival;
}

/**
 * Installed before the page's scripts run: every WebSocket the page opens is
 * kept, and every frame it receives is logged, so a check can read the
 * server's presence pushes off the page's own socket and deliver a peer's
 * push on it the way the server would.
 */
const WS_HOOK = `
  (() => {
    const Native = window.WebSocket;
    const hook = {
      Native,
      sockets: [],
      frames: [],
      second: null,
      // The presence_diff payloads received on topic, oldest first.
      diffs(topic) {
        return hook.frames
          .map((f) => { try { return JSON.parse(f.data); } catch { return null; } })
          .filter((m) => Array.isArray(m) && m[2] === topic && m[3] === "presence_diff")
          .map((m) => m[4]);
      },
      // A server push, as the socket would receive it (Phoenix's V2 frame).
      inject(topic, event, payload) {
        const sock = hook.sockets.find((s) => s.readyState === 1);
        if (!sock) throw new Error("the page has no open socket");
        sock.dispatchEvent(new MessageEvent("message", { data: JSON.stringify([null, null, topic, event, payload]) }));
      },
    };
    window.__ws = hook;
    window.WebSocket = new Proxy(Native, {
      construct(target, args) {
        const sock = new target(...args);
        hook.sockets.push(sock);
        sock.addEventListener("message", (e) => { hook.frames.push({ at: performance.now(), data: String(e.data).slice(0, 4000) }); });
        return sock;
      },
    });
  })();
`;

/** Delivers a peer's `presence_diff` on the page's socket, stamping t0 first. */
async function injectDiff(session, topic, payload) {
  await evaluate(
    session,
    `
    document.dispatchEvent(new Event("cdp-presence"));
    __ws.inject(${JSON.stringify(topic)}, "presence_diff", ${JSON.stringify(payload)});
    return true;
  `,
  );
}

/**
 * A second window of this account, on Phoenix's own wire format: joins
 * `topic` on the same URL the page's socket used (the session cookie is the
 * credential), selects `taskId`, and stays open until closed.
 */
function secondWindow(topic, taskId) {
  return `
    return new Promise((resolve) => {
      const url = __ws.sockets.find((s) => s.readyState === 1)?.url;
      if (!url) return resolve({ ok: false, why: "the page has no open socket to copy" });
      const sock = new __ws.Native(url);
      __ws.second = sock;
      const timer = setTimeout(() => resolve({ ok: false, why: "the join timed out" }), 5000);
      sock.addEventListener("error", () => { clearTimeout(timer); resolve({ ok: false, why: "the socket errored" }); });
      sock.addEventListener("open", () => sock.send(JSON.stringify(["1", "1", ${JSON.stringify(topic)}, "phx_join", {}])));
      sock.addEventListener("message", (e) => {
        let m; try { m = JSON.parse(e.data); } catch { return; }
        if (m[1] !== "1" || m[3] !== "phx_reply") return;
        clearTimeout(timer);
        if (m[4]?.status !== "ok") return resolve({ ok: false, why: "the join was refused: " + JSON.stringify(m[4]) });
        sock.send(JSON.stringify(["1", "2", ${JSON.stringify(topic)}, "select", { task_id: ${taskId} }]));
        resolve({ ok: true });
      });
    });
  `;
}

const CHECKS = [
  ["add a task", checkAddTask],
  ["add a child", checkAddChild],
  ["edit a title in the pane", checkEditTitle],
  ["complete a leaf, parent rolls up", checkCompleteLeaf],
  ["cascade confirm, Cancel", checkCascadeConfirmCancel],
  ["delete confirm, Cancel then Delete", checkDelete],
  ["undo", checkUndo],
  ["redo", checkRedo],
  ["reorder by drag, before band", checkReorder],
  ["reparent by drag, inside band", checkReparent],
  ["forbidden drop", checkForbiddenDrop],
  ["root zone and tail zone", checkRootAndTailZones],
  ["move-flip confirm, Cancel then Proceed", checkMoveFlipConfirm],
  ["sort, and cascade-sort confirm Cancel", checkSort],
  ["selection: click, move, second click, Escape", checkSelection],
  ["Details pane at desktop width", checkPaneDesktop],
  ["Details flyout at phone and tablet width", checkPaneFlyout],
  ["references: render and reveal", checkReferences],
  ["presence: another member's selection", checkPresence],
  ["deep link: ?task= reveals", checkDeepLink],
];

// ---------------------------------------------------------------------------
// Drag driving (7.4). A drag is a press on the row's handle, a glide past the
// 4px threshold (which mounts the zones), a glide to the target, a release.
// ---------------------------------------------------------------------------

/** Presses `id`'s handle and glides until the drag is on; returns the pointer. */
async function beginDrag(session, id) {
  const at = await evaluate(session, `return __tree.handle(${id});`);
  if (at === null) throw new Error(`row #${id} has no drag handle on screen`);
  await mouseMove(session, at);
  await mouseDown(session, at);
  const pointer = { x: at.x, y: at.y + 12 };
  await mouseGlide(session, at, pointer, 3);
  await waitFor(
    session,
    `return __tree.paint().source.includes(${id}) && document.querySelector("#task-tree > li.drop-root-zone") !== null;`,
    { timeoutMs: 2_000, everyMs: 10, what: `the drag of #${id} to begin` },
  );
  return pointer;
}

/** Glides the pressed pointer to `to` and reads what the tree paints there. */
async function dragOver(session, pointer, to) {
  await mouseGlide(session, pointer, to, 3);
  Object.assign(pointer, to);
  // One more move on the spot: the glide's last step may have landed before a
  // scroll the measuring caused settled.
  await mouseMove(session, pointer, { pressed: true });
  return evaluate(session, `return __tree.paint();`);
}

/** A point in one of `id`'s bands: 3px into the edge strips, the row's middle for "center". */
async function bandPoint(session, id, band) {
  const point = await evaluate(session, `return __tree.band(${id}, ${JSON.stringify(band)});`);
  if (point === null) throw new Error(`row #${id} is not on screen`);
  return point;
}

/** The centre of a zone that exists only while a drag is on. */
async function zonePoint(session, selector, what) {
  const point = await waitFor(session, `return __tree.point(${JSON.stringify(selector)});`, { timeoutMs: 2_000, everyMs: 10, what });
  return point;
}

/** `ids` with `id` moved to just before `anchor`. */
function movedBefore(ids, id, anchor) {
  const rest = ids.filter((x) => x !== id);
  const at = rest.indexOf(anchor);
  return [...rest.slice(0, at), id, ...rest.slice(at)];
}

function sameIds(a, b) {
  return Array.isArray(a) && a.length === b.length && a.every((id, i) => id === b[i]);
}

/** A page expression: the list under `parentId` (null: the root) reads exactly `ids`. */
function sameOrder(parentId, ids) {
  return `(JSON.stringify(__tree.order(${parentId})) === ${JSON.stringify(JSON.stringify(ids))})`;
}

/** Completes a leaf by its checkbox and waits for the tree to settle. */
async function completeLeaf(session, id) {
  await armStopwatch(session, "click", `return __tree.rowEl(${id})?.dataset.done === "true";`);
  await clickElement(session, `#task-${id} [data-complete-toggle]`);
  assertAcknowledged(await readStopwatch(session, `row #${id} to show done`), "the done leaf");
  await settle(session);
}

/** Gives a wrongly sent operation the time it would need, then checks nothing went. */
async function assertNothingSent(session, before, what) {
  await new Promise((done) => setTimeout(done, LINK_LATENCY_MS));
  const after = await evaluate(session, `return { tree: __tree.snapshot(), sent: __ops.sent };`);
  if (after.sent !== before.sent) throw new Error(`${what} sent an operation`);
  if (after.tree !== before.tree) throw new Error(`${what} changed the tree`);
}

/** No highlight, placeholder or zone survives a release (item 3.3.3). */
async function assertNothingPainted(session, when) {
  const paint = await evaluate(session, `return { ...__tree.paint(), zones: document.querySelectorAll("#task-tree li.drop-root-zone, #task-tree li.drop-tail").length };`);
  if (paint.source.length > 0 || paint.target !== null || paint.forbidden !== null || paint.placeholder !== null || paint.zones > 0) {
    throw new Error(`the drag's paint is still up ${when}: ${JSON.stringify(paint)}`);
  }
}

/** Bravo{Echo, Foxtrot}, Charlie, Delta after "Alpha, renamed" — one batch through the page. */
async function seedMoveRows(ctx) {
  const { session, initiativeId } = ctx;
  const results = await pageOperations(session, `cdp-tree-${ctx.stamp}-seed-moves`, [
    { op: "add", type: "task", lid: "bravo", data: { initiative_id: initiativeId, title: MOVE_TITLES.bravo } },
    { op: "add", type: "task", data: { initiative_id: initiativeId, title: MOVE_TITLES.charlie } },
    { op: "add", type: "task", data: { initiative_id: initiativeId, title: MOVE_TITLES.delta } },
    { op: "add", type: "task", data: { parent_lid: "bravo", title: MOVE_TITLES.echo } },
    { op: "add", type: "task", data: { parent_lid: "bravo", title: MOVE_TITLES.foxtrot } },
  ]);
  const [bravo, charlie, delta, echo, foxtrot] = results.map((r) => r?.data?.id);
  if (![bravo, charlie, delta, echo, foxtrot].every((id) => typeof id === "number")) {
    throw new Error(`the seed batch did not name five tasks: ${JSON.stringify(results)}`);
  }
  Object.assign(ctx.ids, { bravo, charlie, delta, echo, foxtrot });
  await waitForRows(session, [bravo, charlie, delta, echo, foxtrot], "the seeded rows");
}

/** `CASCADE_SORT_BRANCHES` branches of one leaf each under "Delta". */
async function seedCascadeBranches(ctx) {
  const { session, initiativeId, ids } = ctx;
  const operations = [];
  for (let i = 1; i <= CASCADE_SORT_BRANCHES; i += 1) {
    const lid = `golf-${i}`;
    const n = String(i).padStart(2, "0");
    operations.push({ op: "add", type: "task", lid, data: { initiative_id: initiativeId, parent_id: ids.delta, title: `Golf ${n}` } });
    operations.push({ op: "add", type: "task", data: { parent_lid: lid, title: `Golf ${n} leaf` } });
  }
  const results = await pageOperations(session, `cdp-tree-${ctx.stamp}-seed-cascade`, operations);
  const seeded = results.map((r) => r?.data?.id);
  if (!seeded.every((id) => typeof id === "number")) throw new Error(`the cascade seed did not name every task: ${JSON.stringify(results)}`);
  await waitForRows(session, seeded, "the cascade branches");
}

/** Rows added outside the client arrive by its own refetch on the echo. */
async function waitForRows(session, ids, what) {
  await waitFor(session, `return ${JSON.stringify(ids)}.every((id) => __tree.rowEl(id) !== null);`, {
    timeoutMs: 15_000,
    everyMs: 100,
    what,
  });
  await settle(session);
}

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
    // --- 7.4: order, geometry and the drag's paint ---
    // The ids directly under parentId (null: the root list), in document order.
    order(parentId) {
      const ul = parentId === null ? document.getElementById("task-tree") : document.getElementById("children-" + parentId);
      return ul === null ? null : [...ul.querySelectorAll(":scope > li[data-task-id]")].map((li) => Number(li.dataset.taskId));
    },
    // The centre of the first element matching selector, scrolled into view.
    point(selector) {
      const el = document.querySelector(selector);
      if (el === null) return null;
      el.scrollIntoView({ block: "center", inline: "nearest" });
      const r = el.getBoundingClientRect();
      if (r.width === 0 || r.height === 0) return null;
      return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
    },
    handle(id) {
      return this.point('[data-drag-handle][data-task-id="' + id + '"]');
    },
    // A point in one of id's row bands: 3px into an edge strip (EDGE_PX is 9),
    // the row's middle for "center". Measured on the row strip, not the subtree.
    band(id, band) {
      const row = this.rowEl(id);
      if (row === null) return null;
      row.scrollIntoView({ block: "center", inline: "nearest" });
      const r = row.getBoundingClientRect();
      const y = band === "above" ? r.top + 3 : band === "below" ? r.bottom - 3 : r.top + r.height / 2;
      return { x: Math.round(r.left + r.width / 2), y: Math.round(y) };
    },
    // Everything the drag paints, as ids: the dimmed source, the ringed target,
    // the forbidden ring, the placeholder's slot, the lit root or tail zone.
    paint() {
      const one = (sel) => document.querySelector(sel);
      const idOf = (el, key) => { const n = Number(el?.dataset[key] ?? 0); return n === 0 ? null : n; };
      const ph = one("#task-tree li.drop-placeholder");
      return {
        source: [...document.querySelectorAll("#task-tree li.dragging-source")].map((li) => Number(li.dataset.taskId)),
        target: idOf(one("#task-tree li.drop-target"), "taskId"),
        forbidden: idOf(one("#task-tree li.drop-forbidden"), "taskId"),
        placeholder: ph === null ? null : {
          parent: ph.parentElement.id === "task-tree" ? null : idOf(ph.parentElement, "taskId"),
          next: idOf(ph.nextElementSibling, "taskId"),
        },
        zone: one("#task-tree li.drop-root-zone.is-over")?.dataset.zone ?? null,
        tail: idOf(one("#task-tree li.drop-tail.is-over"), "branch"),
        cursor: document.body.style.cursor,
      };
    },
    // Every descendant's own sort setting, for "Cancel changed nothing".
    sortModes(id) {
      return [...document.querySelectorAll("#task-" + id + " li[data-task-id]")]
        .map((li) => li.dataset.taskId + ":" + li.dataset.sort + ":" + li.dataset.sortReverse)
        .join("|");
    },
    // --- 8.5: selection, the pane, and what is on screen ---
    // The selected row's id (the workspace's li[data-selected]), or null.
    selected() {
      const li = document.querySelector("#task-tree li[data-selected]");
      return li === null ? null : Number(li.dataset.taskId);
    },
    // The Details pane open on a task titled title, with how it is placed —
    // or false. #details-rail[data-open="true"] is the workspace's marker.
    pane(title) {
      const rail = document.getElementById("details-rail");
      if (rail === null || rail.dataset.open !== "true") return false;
      const field = document.getElementById("task-field-title");
      if (field === null || field.value !== title) return false;
      const box = (el) => el !== null && el.getBoundingClientRect().width > 0;
      const backdrop = document.getElementById("pane-backdrop");
      return {
        value: field.value,
        position: getComputedStyle(rail).position,
        backdrop: backdrop === null ? "none" : getComputedStyle(backdrop).display,
        inSlot: rail.parentElement === document.getElementById("client-main")?.parentElement,
        closeVisible: box(rail.querySelector("[data-close-task]")),
        railCloseVisible: box(rail.querySelector("button[data-close-panel]")),
      };
    },
    paneClosed() {
      const rail = document.getElementById("details-rail");
      return (rail === null || rail.dataset.open !== "true") && document.getElementById("task-field-title") === null;
    },
    // The row's top is inside the one scrolling region.
    inView(id) {
      const row = this.rowEl(id);
      if (row === null) return false;
      const r = row.getBoundingClientRect();
      const box = document.getElementById("client-scroll").getBoundingClientRect();
      return r.top >= box.top - 1 && r.top <= box.bottom - 24;
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

/** One operation through the page's own session; its result. */
async function pageOperation(session, key, operation) {
  const [result] = await pageOperations(session, key, [operation]);
  return result ?? null;
}

/** One batch through the page's own session — its cookie, its CSRF token. All or nothing; the results in order. */
async function pageOperations(session, key, operations) {
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
        body: JSON.stringify({ operations: ${JSON.stringify(operations)} }),
      });
      const body = await response.json().catch(() => null);
      const results = body?.data?.results ?? body?.results ?? [];
      if (!response.ok) return { ok: false, why: "answered " + response.status + ": " + JSON.stringify(body?.error ?? body) };
      return { ok: true, results };
    })();
  `,
  );
  if (!reply.ok) {
    const [first] = operations;
    throw new Error(`${first.op} ${first.type}${operations.length > 1 ? ` (+${operations.length - 1})` : ""} ${reply.why}`);
  }
  return reply.results;
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
 * `skipKey/1` in `tree/confirm_model.ts`, one per skippable confirm class (a
 * `.ts` this Node cannot import). The delete confirm has no key.
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

        const ctx = { session, appUrl: APP_URL, initiativeId: throwaway.id, stamp, ids: {} };
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
