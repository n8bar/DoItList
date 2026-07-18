// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/doit"
import topbar from "../vendor/topbar"
import DoitRollup from "./rollup.js"
import {segments, transformForSave, rehydrate} from "./refs.js"

const {computeRollup, computeDoneCascade} = DoitRollup

const Hooks = {}

// localStorage versioning. See .agents/localstorage.md.
// Each feature owns a `<namespace>:_v` sentinel; mismatch drops every
// key under the namespace and writes the current version. Hooks that
// persist client-side state must call this in mounted() before any
// reads or writes to their namespace.
//
// Pass `{ grandfather: true }` when introducing the version check to a
// namespace whose existing key shape and value encoding already match
// the version you're declaring — `null` sentinel will be stamped
// without wiping. Only the *introduction* event benefits; real version
// mismatches still wipe.
function ensureStorageVersion(namespace, currentVersion, opts = {}) {
  const sentinel = `${namespace}:_v`
  const stored = localStorage.getItem(sentinel)
  const target = String(currentVersion)
  if (stored === target) return

  if (stored === null && opts.grandfather) {
    localStorage.setItem(sentinel, target)
    return
  }

  const prefix = `${namespace}:`
  const drop = []
  for (let i = 0; i < localStorage.length; i++) {
    const k = localStorage.key(i)
    if (k && k.startsWith(prefix)) drop.push(k)
  }
  drop.forEach(k => localStorage.removeItem(k))
  localStorage.setItem(sentinel, target)
}

// Shared "saving" hue (.03.03.08): pink the rows a write touches the instant
// the user acts; the authoritative re-render strips the client-added class
// (morphdom reconciles it away), with a timeout as a safety net. Used by the
// keyboard / checkbox / sort / form / delete paths. DragReorder keeps its own
// gesture-coupled variant (it also moves the DOM and clears on the reply).
const SAVING_ROW = "li[data-task-id]"
const savingPending = new Set()
let savingTimer = null

const savingRowOf = (li) => li && (li.firstElementChild || li)

// Ancestor task rows (the chain whose progress / status a rollup write recomputes).
function savingAncestors(li) {
  const acc = []
  let cur = li && li.parentElement && li.parentElement.closest(SAVING_ROW)
  while (cur) {
    if (cur.firstElementChild) acc.push(cur.firstElementChild)
    cur = cur.parentElement && cur.parentElement.closest(SAVING_ROW)
  }
  return acc
}

// The row + every descendant row (for completion cascade / deletion).
const savingSubtree = (li) =>
  li ? [savingRowOf(li), ...[...li.querySelectorAll(SAVING_ROW)].map(savingRowOf)] : []

// The row + its direct child rows (for a sibling resort).
function savingChildren(li) {
  if (!li) return []
  const ul = li.querySelector(":scope > ul[id^='children-']")
  const kids = ul ? [...ul.querySelectorAll(":scope > li[data-task-id]")].map(savingRowOf) : []
  return [savingRowOf(li), ...kids]
}

// --- Ancestor roll-up prediction (m03.02 item 3) ---------------------------
// Paints a REAL predicted progress number / done-state on an ancestor row the
// instant the acting user's own edit is fully known — a leaf's new manual
// progress, or a toggle/cascade snapping its whole subtree to 100/0 — instead
// of the indeterminate "is-recomputing" gradient (kept for every OTHER writer
// whose outcome genuinely can't be known client-side, e.g. another
// collaborator's edit, or the tree-wide progress-calc setting change).
// Mirrors DoIt.Tasks.Progress (leaf-average vs single-level) and the "all
// children done" cascade rule via rollup.js — the one sanctioned client-side
// duplicate of that math (m03.02 cross-cutting requirements). Display only:
// never lands in a push payload; the write's own confirming render (or any
// later broadcast) is always the source of truth and silently overwrites
// whatever's painted here via the existing morphdom reconciliation — no new
// reconciliation machinery.
//
// The whole task tree is always in the DOM (branch collapse is CSS-only —
// see .collapsed-peek), so a DOM query correctly reaches every descendant
// leaf of any ancestor regardless of what's currently expanded on screen.

const isLeafLi = (li) => !li.querySelector(":scope > ul[id^='children-']")

const directChildLis = (li) => {
  const ul = li.querySelector(":scope > ul[id^='children-']")
  return ul ? [...ul.querySelectorAll(":scope > li[data-task-id]")] : []
}

const rowBarValue = (li) => {
  const row = savingRowOf(li)
  const bar = row && row.querySelector("[role='progressbar']")
  return bar ? Number(bar.getAttribute("aria-valuenow")) : 0
}

const rowDone = (li) => {
  const row = savingRowOf(li)
  return !!(row && row.hasAttribute("data-done"))
}

// The Initiative's progress_calc mode, read off #task-tree's own data
// attribute (never hardcoded/assumed) — falls back to leaf_average, the
// server's own default, if the attribute is somehow missing.
const progressCalcMode = () => {
  const tree = document.getElementById("task-tree")
  return tree && tree.dataset.progressCalc === "single_level" ? "single_level" : "leaf_average"
}

// Every descendant LEAF value under `li` (leaf_average mode's input),
// substituting `forcedValue` for any leaf under (or at) `forcedLi` — a plain
// leaf edit forces just itself; a completion toggle/cascade forces its whole
// subtree uniformly (every descendant leaf snaps to the same new 100/0).
function leafValuesUnder(li, forcedLi, forcedValue) {
  if (isLeafLi(li)) return [forcedLi.contains(li) ? forcedValue : rowBarValue(li)]
  return directChildLis(li).flatMap((c) => leafValuesUnder(c, forcedLi, forcedValue))
}

// Ascends `ancestors` (row divs, nearest-parent first — savingAncestors'
// own order) predicting each one's rolled-up progress + done-state.
// `forcedLi` is the node whose new value is already known (the edited leaf,
// or the toggled leaf/branch); `forcedValue` (0-100) / `forcedDone` are its
// new progress and done-state. Returns [{row, li, progress, done}], nearest
// ancestor first — each level's OWN freshly-predicted value feeds the next
// level up (single_level's direct-children average needs it; leaf_average
// doesn't, since it always walks down to real leaves, but tracking both
// costs nothing extra and keeps one code path for both modes).
function predictAncestors(ancestors, forcedLi, forcedValue, forcedDone) {
  const mode = progressCalcMode()
  const progressOverride = new Map([[forcedLi.dataset.taskId, forcedValue]])
  const doneOverride = new Map([[forcedLi.dataset.taskId, forcedDone]])

  return ancestors
    .map((row) => {
      const li = row.closest("li[data-task-id]")
      const kids = li ? directChildLis(li) : []
      if (!li || kids.length === 0) return null

      const progressValues =
        mode === "single_level"
          ? kids.map((k) => progressOverride.get(k.dataset.taskId) ?? rowBarValue(k))
          : leafValuesUnder(li, forcedLi, forcedValue)
      const progress = computeRollup(progressValues, mode)
      const done = computeDoneCascade(
        kids.map((k) => doneOverride.get(k.dataset.taskId) ?? rowDone(k))
      )

      progressOverride.set(li.dataset.taskId, progress)
      doneOverride.set(li.dataset.taskId, done)
      return {row, li, progress, done}
    })
    .filter((p) => p != null)
}

function markSaving(rows, opts = {}) {
  rows.forEach((el) => {
    if (el) { el.classList.add("is-saving"); savingPending.add(el) }
  })
  if (savingTimer) { clearTimeout(savingTimer); savingTimer = null }
  // sticky: a client-held maybe-write (the delete confirm, while open) — no
  // safety timeout; whoever closes the dialog clears the hue explicitly.
  if (!opts.sticky) savingTimer = setTimeout(clearSavingHue, 1500)
}

function clearSavingHue() {
  savingPending.forEach((el) => el.classList.remove("is-saving", "is-recomputing"))
  savingPending.clear()
  if (savingTimer) { clearTimeout(savingTimer); savingTimer = null }
}

// Rows whose % is genuinely in flight — pinked by a progress-affecting write
// but NOT the operated row (its values are set optimistically) — also show
// the indeterminate gradient (.03.07.23): the bar can't claim a number it
// doesn't know. Same lifecycle as the pink (cleared together, stripped by
// the patch).
function markRecomputing(rows) {
  rows.forEach((el) => {
    if (el) { el.classList.add("is-recomputing"); savingPending.add(el) }
  })
}

// Hand the hue to the server: once a confirm modal is up, the same rows hold
// the SERVER-rendered maybe-write pink (pending_saving_ids) — the client
// stops tracking WITHOUT stripping classes, so the 1.5s safety timer can't
// unpink a still-deciding modal (§-finding: Proceed looked like it unpinked;
// the timer had already eaten the hue).
function releaseSavingHue() {
  savingPending.clear()
  if (savingTimer) { clearTimeout(savingTimer); savingTimer = null }
}

const selectedLi = () => document.querySelector("li[data-selected]")

// The colocated TaskKeys hook can't import, so reach it through the window.
window.DoitSaving = {
  markSaving,
  markRecomputing,
  savingAncestors,
  savingSubtree,
  savingChildren,
  selectedLi,
  savingRowOf,
}

// The single source of client-owned truth (worklist 2). One unified store that
// survives every server re-render, reconnect, and initial connect — read by the
// `dom:` callbacks below so the right value is reconciled INSIDE the morphdom
// patch (never painted wrong, no post-hoc race). It supersedes the fragmented
// `window.Doit*` objects; features migrate onto it slice by slice. This slice
// activates `selectedId` only — the other fields are declared so the shape is
// fixed for the slices that follow (open editor/details, optimistic flips,
// collaborator presence, keyboard focus/caret).
const DoitState = {
  selectedId: null, // string|null — the client-owned task selection (active)
  editorOpen: false, // initiative editor visibility — slice 2.3
  detailsOpen: {}, // {[elId]: bool} — open/closed of data-keep="open" <details> (active)
  // Comment editors & popups are client-owned (WL3 3.3, §6.5): which comment's
  // inline edit form is open, and which comment's edit-history popup is open.
  // string|null comment ids; the "comment-edit" / "comment-versions" appliers
  // read these so a list-refresh patch can't snap an open editor/popup shut.
  commentEditId: null, // string|null — the comment whose inline editor is open
  commentVersionsId: null, // string|null — the comment whose history popup is open
  // Confirm-held / drop-held optimistic structural holds. `toggle`/`move` are
  // slice 2.3; `initiativeOrder` (WL3.5 Fix A) holds a drag-reordered Initiatives
  // card order {wrapId, order:[ids], prior:[ids]} at drop until the apply_sort
  // reply settles (release on ok, revert to prior on failure) — re-asserted by
  // applyPendingInitiativeOrder from onPatchEnd, mirroring applyPendingMove.
  pending: {toggle: null, move: null, initiativeOrder: null},
  // Optimistic rail member-avatar chips (WL3.5 Fix B), keyed by echo id →
  // {iid, uid, name, initials, bg, fg}. A drag-collaborator-onto-initiative drop
  // inserts the dropped user's avatar into that rail entry's avatar row at once;
  // the `rail-avatars` KeepRegistry applier re-inserts it across mid-flight
  // patches until the add_collaborator_to reply clears the entry (ok → the
  // server's rail refresh renders the real avatar; failure → pulled, MUST NOT LIE).
  railAvatarAdds: {}, // {[echoId]: {iid, uid, name, initials, bg, fg}}
  presence: {selections: [], online: []}, // collaborator presence badges — slice 2.3
  // Inner scroll-container offsets, keyed by element id (slice 2.3.8). LiveView
  // preserves window scroll on navigate and, because we keep every scroll box at
  // a stable id, its scrollTop survives an in-place morph for free — but NOT the
  // remove-and-re-add path (initial-join replace / a future stream reset), which
  // re-creates the node at scrollTop 0. This store is the truth the "scroll"
  // KeepRegistry applier restores onto the re-added node. (Focus + caret are
  // fully covered by LiveView for this app — every focusable lives at a stable
  // id, so node identity + LV's restoreFocus carry them; nothing to keep here.)
  scroll: {}, // {[elId]: number} — captured scrollTop of data-keep="scroll" boxes
  // Group-by-Initiative reflow (WL3 3.2, §6.5): client-owned arrangement, keyed
  // by the Assigned-list wrapper id → the optimistic grouped? value. The pref
  // persists on the round-trip; this bridges the click until the server render
  // agrees, then the "assigned-group" applier releases the hold.
  assignedGrouped: {}, // {[wrapperId]: bool}
  // Server-gated reveal toggles (WL3 3.2, §6.7), keyed by checkbox id → the
  // optimistic checked value. The rows are server-FILTERED, so the client can't
  // reveal them — this only holds the CONTROL's own tick + aria-busy until the
  // server's re-render agrees. It never paints phantom rows.
  revealInflight: {}, // {[checkboxId]: bool}
  // Archive-on-completion banner dismissal (WL3 3.2, §6.5): hidden instantly at
  // the click; the flag holds it hidden across any mid-flight patch until the
  // server's dismiss reply removes the element (onPatchEnd then clears it).
  archivePromptDismissed: false,
  // §6.8 dead-window capture queue (WL4.2.2/4.2.3): server-gated writes taken
  // before the LiveView is live are captured here as ordered {key, ev, payload,
  // cb} entries and flushed, in order, on connect (see DoitPush below). In-memory
  // only — never persisted (entries hold reply callbacks).
  preconnectQueue: [],
}
window.DoitState = DoitState

// --- §6.8 dead-window capture-and-replay (WL4.2.2 / 4.2.3) ------------------
//
// A LiveView page paints ~2.8s before it's live (the dead window). Server-gated
// writes funnel through window.DoitPush; until 4.2.2 that funnel existed only
// AFTER the root hook mounted (post-connect), so a dead-window call hit
// `undefined` and vanished. Here DoitPush exists from module load: when live it
// dispatches immediately through the mounted root hook's pushEvent; in the dead
// window it CAPTURES the call onto DoitState.preconnectQueue (deduped per the
// policy below), and the root hook flushes the queue, in order, the instant it
// mounts (= channel join = "now live"). The caller's optimistic / in-flight ack
// already stood at the click, so nothing is lost, and the server stays
// authoritative on flush — the preserved reply cbs + KeepRegistry appliers
// reconcile exactly as in steady state, and a refusal bonks/reverts through the
// existing paths (MUST NOT LIE — never an unsent success).
//
// The live backend is a root hook's bound pushEvent: null in the dead window
// and during a navigate teardown→remount gap; set for the life of a mounted
// view. It is NOT re-set on reconnect (the hook isn't re-mounted), so the queue
// is a FIRST-connect mechanism only — a reconnect re-joins on its own and never
// re-flushes committed work (the queue is already empty by then).
let livePush = null

// Coalesce policy: return a stable key when re-enqueuing this event should
// REPLACE the prior queued entry (last-write-wins, kept at its original
// position), or null to APPEND (every distinct act preserved, in order).
// Default (event absent here) = append — safe: never silently drops a distinct
// intent (§6 / [[feedback_optimistic_ui_must_not_lie]]).
function preconnectCoalesceKey(ev, payload) {
  const p = payload || {}
  switch (ev) {
    // Singleton view prefs — only the FINAL choice matters, so each collapses to
    // one entry (last-write-wins, kept at its original queue position). As of
    // WL4.2.2 these reach the queue for real: they ride native phx-change /
    // phx-click and are captured by the live-gated interceptor below.
    case "set_index_style":
    case "set_progress_calc":
    case "set_viewer_plus":
    case "update_subtitle":
    case "update_initiative": // editor form — change (validate) + submit (save)
    case "assigned_toggle_group_by":
    case "assigned_toggle_completed":
    case "assigned_toggle_archived_hidden":
    case "validate_profile":
    case "validate_username":
    case "validate_password":
    case "validate_preferences":
      return ev
    // Sort lives on ONE reused form that is re-pointed at the selected branch
    // (its hidden task_id follows the selection), so coalesce PER BRANCH — a
    // later branch's sort must not overwrite an earlier branch's queued change.
    case "set_sort":
      return "set_sort:" + (p.task_id || "")
    // One role form per member (hidden user_id) — coalesce per member so two
    // members' role changes both replay; repeats on one member last-write-win.
    case "update_member_role":
      return "update_member_role:" + (p.user_id || "")
    // Inline pane edits: keyed per (TARGET TASK, form). p.id is the task the
    // edit was made against (preconnectSelfTarget captures DoitState.selectedId),
    // so cross-task dead-window edits don't collide. The field SET distinguishes
    // the TWO split update_task forms (form 1 title/description/manual_progress vs
    // form 2 priority/assignee), so neither partial overwrites the other; each
    // form's keystrokes still coalesce last-write-wins.
    case "update_task":
      return "update_task:" + (p.id || "") + ":" + (p.task ? Object.keys(p.task).sort().join(",") : "")
    // Structural move / cascade: latest intent per target wins (these carry a
    // single latest intent in DoitState.pending.*). move_task is a hook gesture
    // (post-connect), so it won't reach the queue — declared for completeness; a
    // directional branch cascade is idempotent per (event, row).
    case "move_task":
      return "move_task:" + p.task_id
    case "cascade_complete":
    case "cascade_incomplete":
      return ev + ":" + p.id
    // APPEND (default, key null) — every distinct act preserved, in order:
    //   • create_task / add_comment / save_comment / add_member / create /
    //     confirm_handoff — distinct creates / submits, never merged.
    //   • toggle_complete / toggle_show_hidden and the archived row actions
    //     (hide / unhide / unarchive / restore_initiative) are server-side FLIPS
    //     or per-row acts: two flips must BOTH replay (a coalesced single flip
    //     would desync the optimistic net from the server).
    //   • select_task / close_task never reach the queue — see PRECONNECT_SKIP /
    //     DOITPUSH_OWNED (selection is replayed from the final DoitSelection).
    default:
      return null
  }
}

// Selection is replayed separately by the .TaskKeys mount, which pushes the
// FINAL selection from DoitSelection.id (the selection slot's single source of
// truth — it also captures pill-click selections, which never call DoitPush). So
// don't ALSO queue select_task/close_task: that would double-push the selection.
const PRECONNECT_SKIP = new Set(["select_task", "close_task"])

function enqueuePreconnect(ev, payload, cb) {
  const key = preconnectCoalesceKey(ev, payload)
  const q = DoitState.preconnectQueue
  const entry = {key, ev, payload, cb}
  if (key != null) {
    const at = q.findIndex((e) => e.key === key)
    if (at !== -1) { q[at] = entry; return } // last-write-wins at a stable position
  }
  q.push(entry)
}

// THE single server-gated write funnel (every delegated listener calls it).
// Live → dispatch now (cb receives the reply, exactly as before). Dead window →
// capture for the flush. No call site changed: callers that guarded on
// `window.DoitPush` being defined now always proceed, so their dead-window
// action is captured instead of dropped — which is the whole point of §6.8.
window.DoitPush = (ev, payload = {}, cb) => {
  if (livePush) return livePush(ev, payload, cb)
  if (PRECONNECT_SKIP.has(ev)) return // owned by the .TaskKeys selection replay
  enqueuePreconnect(ev, payload, cb)
}

// Flush every captured entry, in original order, through the now-live backend,
// then clear. Cleared BEFORE dispatch so a flushed event's synchronous re-entry
// (now live) sends immediately rather than re-queuing or re-flushing.
function flushPreconnect() {
  if (!livePush || DoitState.preconnectQueue.length === 0) return
  const batch = DoitState.preconnectQueue
  DoitState.preconnectQueue = []
  for (const {ev, payload, cb} of batch) livePush(ev, payload, cb)
}

// A root hook calls these from mounted()/destroyed(): registering its bound
// pushEvent IS the "now live" signal (the hook mounts only after the channel
// joins) and triggers the flush; unregister is keyed on the fn so a navigate
// where the next view mounts before the old is destroyed can't null a live
// backend. As of M02.09 WL5.4 the index and detail are ONE kept-mounted
// workspace LiveView, so a single always-present .Workspace shell hook registers
// (and never unregisters on a list<->detail patch) — the dead window exists only
// at first connect, not on every hop.
window.DoitRegisterLivePush = (fn) => { livePush = fn; flushPreconnect() }
window.DoitUnregisterLivePush = (fn) => { if (livePush === fn) livePush = null }

// `data-keep="<kind>"` registry. Each client-owned element carries a
// server-rendered `data-keep` marker naming its kind; the entry's `apply(el,
// state)` reconciles that one element to the store's truth, idempotently
// (writes only when the DOM disagrees, removes the attribute when it shouldn't
// be there). The `dom:` callbacks dispatch into this by `el.dataset.keep`, so a
// new client-owned element joins the preserve path by rendering the marker — no
// per-feature observer. This slice registers `"selected"`; later slices add the
// editor/pane, optimistic-flip, presence, and focus kinds.
const KeepRegistry = {
  selected: {
    // Match the task-row <li>'s data-selected to state.selectedId. Set when this
    // li IS the selection (and isn't already marked); remove otherwise.
    apply(el, state) {
      const id = el.dataset.taskId
      const want = state.selectedId != null && id === String(state.selectedId)
      if (want) {
        if (el.getAttribute("data-selected") !== id) el.setAttribute("data-selected", id)
      } else if (el.hasAttribute("data-selected")) {
        el.removeAttribute("data-selected")
      }
    },
  },
  editor: {
    // The initiative-editor pane (#initiative-editor-pane). Visibility is client
    // truth (state.editorOpen); the server always renders it hidden. Reconcile
    // the `hidden` attribute: open => not hidden, closed => hidden.
    apply(el, state) {
      const wantHidden = !state.editorOpen
      if (el.hidden !== wantHidden) el.hidden = wantHidden
    },
  },
  pane: {
    // The task Details pane (#task-editor-pane). Like `selected`/`editor`, its
    // open/closed state is client truth — a task is selected (state.selectedId)
    // => open. But unlike those it also carries SERVER-backed content (the row
    // fields + the comments/activity lists). On a reconnect join the server
    // re-renders it hidden (selection is client-owned, nil on rejoin) while the
    // SURVIVING DoitState.selectedId means it should be open and row-filled, so
    // without this applier the pane closes on reconnect (WL7.3.2.6) even though
    // the highlight survives. WL2.4 retired the old reassertClientState ->
    // DoitSelection.apply() reconnect re-assert and never gave the pane an
    // equivalent — this is it. Reconcile the `hidden` attr to the surviving
    // selection (so the wrong value never paints when this runs on `toEl` before
    // morphdom copies it), then drive syncPaneSkeleton() — idempotent — to
    // re-open + re-fill the row-derived fields (title/priority/assignee/progress)
    // and show the in-flight "Loading…" skeleton for the server-backed lists
    // until the selection re-syncs. A deliberately-closed pane (selectedId
    // cleared) reconciles to hidden and stays closed, so normal open/close and
    // the pane/rail close are untouched.
    //
    // The syncPaneSkeleton here finalizes the fill when this element IS the final
    // node — onNodeAdded (a re-added subtree, e.g. the A->B switch re-assert that
    // calls DoitApplyKeep directly) — where nothing overwrites it after. The
    // reconnect join is instead an IN-PLACE morphdom patch (performPatch): morph
    // would clobber the just-filled non-focused inputs back to the server's blank
    // render, so the post-patch refill that actually lands on reconnect runs from
    // onPatchEnd (below) on the settled DOM. Both call the same idempotent fill.
    apply(el, state) {
      const wantHidden = !state.selectedId
      if (el.hidden !== wantHidden) el.hidden = wantHidden
      if (window.DoitSelection) window.DoitSelection.syncPaneSkeleton()
    },
  },
  "editor-signifier": {
    // The title/subtitle "click to edit" affordance ([data-edit-initiative]). The
    // `.editor-open` class marks the affordance as pressed/active while its editor
    // is open; the server can no longer toggle it, so the client owns it via state.
    apply(el, state) {
      if (el.classList.contains("editor-open") !== state.editorOpen) {
        el.classList.toggle("editor-open", state.editorOpen)
      }
    },
  },
  rail: {
    // The mobile right-rail flyout (#details-rail). Its `data-open` AND the
    // sibling #pane-backdrop's `hidden` are pure VIEW STATE (.03.07.20): open
    // when a task is selected OR the initiative editor is showing — both client
    // truth. The server renders both SOLELY from @selected_task_id, so the
    // editor-open case (selectedId null) leaves them unmanaged and a patch
    // strips/resets them. This kind owns BOTH elements (the backdrop carries no
    // marker of its own) and mirrors syncRail's computation, idempotently (no-op
    // when already matched). `el` is #details-rail (where the marker renders).
    apply(el, state) {
      const open = !!(state.selectedId || state.editorOpen)
      if (el.hasAttribute("data-open") !== open) el.toggleAttribute("data-open", open)
      const backdrop = document.getElementById("pane-backdrop")
      if (backdrop && backdrop.hidden !== !open) backdrop.hidden = !open
    },
  },
  presence: {
    // The presence anchor (#presence-badges, phx-update="ignore"). Truth lives in
    // state.presence (written by the PresenceBadges handleEvent). Painting is
    // document-wide and idempotent (per-slot signature guard, no-op class
    // toggles), so reconciling on this one element repaints every row badge /
    // online dot to match the store after any patch re-adds or touches it.
    apply(_el, _state) {
      applyPresenceBadges()
    },
  },
  collapse: {
    // A children <ul> (ul[id^='children-']). Truth stays in localStorage (keyed
    // by initiative+task); reconcile the `.collapsed-peek` class to it. The
    // server never renders the class, so this is purely additive — set when the
    // stored state is collapsed, removed otherwise. No-op toggle when matched.
    apply(el, _state) {
      const key = `phx:collapse:${el.dataset.initiativeId}:${el.dataset.taskId}`
      const collapsed = localStorage.getItem(key) === "1"
      if (el.classList.contains("collapsed-peek") !== collapsed) {
        el.classList.toggle("collapsed-peek", collapsed)
      }
    },
  },
  open: {
    // A preserved <details> (details[data-keep="open"]). Its expanded/collapsed
    // state is client truth (state.detailsOpen[el.id], written by the delegated
    // `toggle` listener below); the server re-renders it at its default, so a
    // patch would otherwise snap it shut. Reconcile `el.open` to the stored
    // value when an entry exists, idempotently (write only when it differs).
    // No entry → the user hasn't touched it; leave the server default alone.
    apply(el, state) {
      if (!(el.id in state.detailsOpen)) return
      const want = !!state.detailsOpen[el.id]
      if (el.open !== want) el.open = want
    },
  },
  "comment-edit": {
    // A comment <li> (li[data-keep="comment-edit"]). Its inline editor's
    // open/close is client truth (state.commentEditId, written by the delegated
    // click listener below); the server renders BOTH the display block and the
    // author's form (form hidden by default) and never knows which is open, so a
    // patch would otherwise snap the editor shut. Reconcile by toggling `hidden`
    // on this row's [data-comment-display] and [data-comment-edit-form] to match
    // whether THIS comment is the open one. Idempotent (no-op when matched). A
    // tombstoned/non-author row has neither child — the lookups are null-safe.
    apply(el, state) {
      const editing = state.commentEditId != null && el.id === `comment-${state.commentEditId}`
      const display = el.querySelector("[data-comment-display]")
      const form = el.querySelector("[data-comment-edit-form]")
      if (display && display.hidden !== editing) display.hidden = editing
      if (form && form.hidden === editing) form.hidden = !editing
    },
  },
  "comment-versions": {
    // A comment's edit-history popup (div[data-keep="comment-versions"], id
    // `comment-versions-<id>`). Its visibility is client truth
    // (state.commentVersionsId); the server renders it hidden and never knows
    // it's open, so a patch would snap it shut. Reconcile `hidden` to whether
    // THIS popup's comment is the open one. Idempotent.
    apply(el, state) {
      const want =
        state.commentVersionsId != null &&
        el.id === `comment-versions-${state.commentVersionsId}`
      if (el.hidden !== !want) el.hidden = !want
    },
  },
  "pending-toggle": {
    // The operated task row ([data-task-row], the <li>'s child — the <li>
    // itself already carries data-keep="selected", and an element can hold only
    // one data-keep, so the pending-toggle marker rides the child). While
    // state.pending.toggle holds a flip for THIS row, re-apply the optimistic
    // aria-pressed / data-done / bar onto the incoming node so a patch landing
    // mid-flight can't revert it. Once the incoming SERVER render already shows
    // the flip (data-done matches), release the hold — the server owns the row
    // from there. When no hold targets this row, leave the server value alone.
    apply(el, state) {
      const p = state.pending.toggle
      const li = el.closest("li[data-task-id]")
      if (!p || !li || li.id !== p.liId) return
      const toggle = el.querySelector("[data-complete-toggle]")
      if (!toggle) return
      // The server has committed (reply landed) AND this incoming render already
      // agrees with the optimistic flip → settled; drop the hold so we stop
      // overriding the authoritative value. Before commit, or before the render
      // catches up, keep holding so the gap can't revert the flip.
      if (p.committed && el.hasAttribute("data-done") === p.value) {
        state.pending.toggle = null
        return
      }
      const want = String(p.value)
      if (toggle.getAttribute("aria-pressed") !== want) {
        toggle.setAttribute("aria-pressed", want)
        toggle.setAttribute("aria-label", p.value ? "Reopen task" : "Mark task completed")
      }
      if (el.hasAttribute("data-done") !== p.value) el.toggleAttribute("data-done", p.value)
      if (p.barValue != null) setRowBar(el, p.barValue)
    },
  },
  "pending-toggle-slider": {
    // The pane's manual-progress slider (#task-field-progress). Held to the
    // pending toggle's optimistic value (100 on complete, 0 on reopen) while the
    // flip is in flight FOR THE TASK THE PANE IS SHOWING, so a patch can't snap
    // it back before the reconciling render. Yields to the server value once the
    // hold is released (the row applier clears it on match).
    apply(el, state) {
      const p = state.pending.toggle
      if (!p || p.sliderValue == null || el === document.activeElement) return
      const pane = document.getElementById("task-editor-pane")
      const li = document.getElementById(p.liId)
      if (!pane || !li || pane.dataset.taskId !== li.dataset.taskId) return
      const v = String(p.sliderValue)
      if (el.value !== v) el.value = v
      const readout = pane.querySelector("[data-progress-readout]")
      if (readout && readout.textContent !== v) readout.textContent = v
    },
  },
  scroll: {
    // An inner scroll container (e.g. #tree-scroll). Its scrollTop is client
    // truth (state.scroll[el.id], written by the capturing `scroll` listener
    // below). On an in-place morph the live node keeps its identity so scrollTop
    // survives untouched — but morphdom can remove-and-re-add the node (the
    // initial-join replace, a future stream reset), which re-creates it at 0.
    // Restore the captured offset when an entry exists and the node disagrees;
    // no entry → the user hasn't scrolled it, leave it alone. Idempotent: a
    // matching scrollTop is a no-op, so this is safe on every patch path.
    apply(el, state) {
      if (!(el.id in state.scroll)) return
      const want = state.scroll[el.id]
      if (el.scrollTop !== want) el.scrollTop = want
    },
  },
  "assigned-group": {
    // The Assigned-to-Me list wrapper (div[data-keep="assigned-group"]).
    // Group-by is pure arrangement (WL3 3.2, §6.5): data-grouped decides which
    // of the always-rendered group headers / row subtitles the CSS shows. The
    // value flips instantly at the click; hold the optimistic value until the
    // server's persisted pref renders the same, then release so the server owns
    // it. No entry → the user hasn't toggled; leave the server-rendered value.
    apply(el, state) {
      if (!(el.id in state.assignedGrouped)) return
      const want = !!state.assignedGrouped[el.id]
      const incoming = el.getAttribute("data-grouped") === "true"
      if (incoming === want) {
        delete state.assignedGrouped[el.id]
        return
      }
      el.setAttribute("data-grouped", String(want))
    },
  },
  "assigned-group-box": {
    // The Group-by checkbox. Held to the wrapper's optimistic grouped? value so
    // a mid-flight patch can't revert the tick before the pref reply lands.
    // Yields to the server value once the wrapper applier releases the hold
    // (entry gone) — they render from the same assign, so they settle together.
    apply(el, state) {
      const wrapId = el.dataset.groupWrap
      if (!(wrapId in state.assignedGrouped)) return
      const want = !!state.assignedGrouped[wrapId]
      if (el.checked !== want) el.checked = want
    },
  },
  "reveal-toggle": {
    // A server-gated reveal checkbox (show-completed / show-archived-hidden /
    // show-hidden, WL3 3.2, §6.7). Its rows are server-FILTERED, so the client
    // can't reveal them alone: the round-trip stays, and this only holds the
    // CONTROL's own optimistic tick + aria-busy until the server's re-render
    // agrees — it NEVER paints phantom rows. agree → release; disagree while
    // still in flight (the live node keeps phx-click-loading) → hold the tick;
    // disagree once settled (class gone) → the server rejected the flip, so
    // revert honestly by releasing and letting the server value stand.
    apply(el, state) {
      // doit-reveal-busy is the connect-independent twin of phx-click-loading
      // that drives the spinner (WL4.3) — cleared/held in lockstep with aria-busy.
      const clearBusy = () => {
        if (el.getAttribute("aria-busy") === "true") el.removeAttribute("aria-busy")
        el.classList.remove("doit-reveal-busy")
      }
      const want = state.revealInflight[el.id]
      if (want === undefined) {
        clearBusy()
        return
      }
      if (el.checked === want) {
        delete state.revealInflight[el.id]
        clearBusy()
        return
      }
      const live = document.getElementById(el.id)
      const inFlight = live && live.classList.contains("phx-click-loading")
      if (!inFlight) {
        delete state.revealInflight[el.id]
        clearBusy()
        return
      }
      el.checked = want
      el.setAttribute("aria-busy", "true")
      el.classList.add("doit-reveal-busy")
    },
  },
  "archive-prompt": {
    // The archive-on-completion banner (#archive-prompt). Dismissal is client-
    // owned view state (WL3 3.2, §6.5): hidden at the click. The server's
    // dismiss reply removes the element, but until it lands the banner is still
    // rendered (show_archive_prompt true), so a mid-flight collaborator patch
    // would otherwise re-show it — hold it hidden while the dismissed flag
    // stands. onPatchEnd clears the flag once the server has removed the
    // element, so a later re-raise (a fresh 100% crossing) shows normally.
    apply(el, state) {
      if (state.archivePromptDismissed && !el.hidden) el.hidden = true
    },
  },
  "rail-avatars": {
    // A rail Initiative entry's member-avatar row (#rail-avatars-<iid>). A
    // drag-collaborator-onto-initiative drop (WL3.5 Fix B, §6.2) optimistically
    // inserts the dropped user's avatar chip into this row's group at once; the
    // add is server-gated (owner-only, may already be a member), so the chip is
    // held by a railAvatarAdds entry until the add_collaborator_to reply lands.
    // Re-insert any pending chip for THIS Initiative the incoming render doesn't
    // already carry (deduped by data-member-id) so a mid-flight patch — e.g. a
    // presence diff repainting the rail — can't strip it before the reply. The
    // reply (or its 8s safety timeout) clears the entry; once cleared this is a
    // no-op and the server-rendered members stand (MUST NOT LIE on failure).
    apply(el, state) {
      const iid = el.dataset.railAvatarsInitiativeId
      const group = el.querySelector("[data-rail-avatar-group]")
      if (!group) return
      for (const echoId of Object.keys(state.railAvatarAdds)) {
        const a = state.railAvatarAdds[echoId]
        if (String(a.iid) !== String(iid)) continue
        if (group.querySelector(`[data-member-id="${a.uid}"]`)) continue
        group.appendChild(buildRailAvatarChip(echoId, a))
      }
    },
  },
}

// Reconcile one keep-marked element to the store. Shared by both `dom:`
// callbacks. On update we operate on `toEl` (the incoming node) so the truth is
// in place BEFORE morphdom copies it onto the live element — the wrong value
// never paints. On re-add we operate on the freshly inserted node.
function applyKeep(el, state) {
  if (!el || !el.dataset) return
  const entry = KeepRegistry[el.dataset.keep]
  if (entry) entry.apply(el, state)
}

// Exposed for the colocated TaskKeys hook (can't import): after a client-owned
// open/close flip, re-apply one keep element immediately so the view reflects
// the new state without waiting for the next patch (e.g. the "comment-saved"
// push closes the editor — re-run the row's "comment-edit" applier at once).
window.DoitApplyKeep = (el) => applyKeep(el, DoitState)

// Client-owned selection (UX_GUARDRAILS 6.5): the highlight is a DOM attribute
// + CSS, applied instantly and re-applied across re-renders by the guard
// observer below — the server only ever hears about it to load the Details
// pane. `lastId` backs the Enter toggle's "reselect what I had" behavior.
// `id` is a getter/setter backed by DoitState.selectedId so selection has a
// single source of truth: the preserve-path `dom:` callbacks and this object's
// immediate apply() both read the same value and stay consistent.
const DoitSelection = {
  get id() { return DoitState.selectedId },
  set id(v) { DoitState.selectedId = v },
  lastId: null,
  li() { return this.id ? document.getElementById("task-" + this.id) : null },
  set(id, opts = {}) {
    id = String(id)
    if (this.id && this.id !== id) this.lastId = this.id
    this.id = id
    this.apply()
    if (opts.scroll) {
      const li = this.li()
      if (li) (li.firstElementChild || li).scrollIntoView({block: "nearest"})
    }
  },
  clear() {
    if (this.id) this.lastId = this.id
    this.id = null
    this.apply()
  },
  // Idempotent: setting an attribute to its current value doesn't mutate, so
  // re-applying from the preserve-path callbacks is a safe no-op when matched.
  apply() {
    document.querySelectorAll("li[data-selected]").forEach((li) => {
      if (!this.id || li.id !== "task-" + this.id) li.removeAttribute("data-selected")
    })
    const li = this.li()
    if (li && li.getAttribute("data-selected") !== this.id) {
      li.setAttribute("data-selected", this.id)
    }
    this.syncPaneSkeleton()
  },
  // ONE pane, never swapped (.03.07.06): the pane stays mounted once created.
  // While a selection switch is in flight (the pane's data-task-id doesn't
  // match the client selection yet), the row-known values are written into
  // the REAL fields immediately and the server-only sections dim; the server
  // patch reconciles the same elements in place. Value writes are properties
  // (not attributes) and skip the focused element, so re-applying converges
  // and in-progress typing survives.
  syncPaneSkeleton() {
    // Selecting a task always leaves the initiative editor (.03.07.08) — close
    // it through the client-owned flag so the preserve path keeps it closed.
    if (this.id) DoitInitiativeEditor.close({skipSelectionClear: true})
    const pane = document.getElementById("task-editor-pane")
    if (pane) {
      const arrived = pane.dataset.taskId === this.id
      const shouldHide = !this.id
      if (pane.hidden !== shouldHide) pane.hidden = shouldHide
      // Server-only lists (comments, activity) swap to an explicit "Loading…"
      // while a switch is in flight — never another task's data, dimmed or
      // otherwise. The add-comment form stays live: select_task enters the
      // event queue first, so an immediate comment lands on the new task.
      const inFlight = !!this.id && !arrived
      pane.querySelectorAll("[data-async-list]").forEach((el) => {
        if (el.hidden !== inFlight) el.hidden = inFlight
      })
      pane.querySelectorAll("[data-async-loading]").forEach((el) => {
        if (el.hidden !== !inFlight) el.hidden = !inFlight
      })
      // The optimistic co-list stands in only while a switch is in flight;
      // once the real list arrives (or nothing is selected) hide it. While in
      // flight, fillPaneFields fills it and sets its own hidden by seed count.
      const coOpt = pane.querySelector("#co-optimistic")
      if (coOpt && !inFlight) coOpt.hidden = true
      if (inFlight) this.fillPaneFields(pane)
      // A pill tap on a first-ever selection parked its field focus until the
      // pane existed (.03.07.17) — land it now.
      if (arrived && window.DoitPendingFocus) {
        const field = document.getElementById(window.DoitPendingFocus)
        window.DoitPendingFocus = null
        if (field && !field.disabled) {
          field.focus()
          field.scrollIntoView({block: "nearest"})
        }
      }
    }
    syncRail()
  },
  fillPaneFields(pane) {
    const li = this.li()
    const row = li && li.querySelector(":scope > [data-task-row]")
    if (!row) return
    const text = (sel) => {
      const el = row.querySelector(sel)
      return el ? el.textContent.trim() : ""
    }
    const set = (el, value) => {
      if (el && el !== document.activeElement && el.value !== value) el.value = value
    }

    // Ref-bearing title/description (Wave 2): after the read-path render, the
    // row's textContent is link LABEL text ("1.5", no leading `%`, escapes
    // resolved) — an optimistic fill would put a mis-formatted, mis-saveable
    // value in the box. A NOT-yet-rendered row is just as unsafe: its text is
    // still the raw `%<id>` token (a mid-patch fill can run before the render
    // pass). Skip both; the server value + RefField.rehydrate() supply the
    // correct `%label` a beat later. Ref-free fields keep the instant
    // optimistic fill.
    const hasRef = (sel) => {
      const el = row.querySelector(sel)
      return !!(
        el &&
        (el.querySelector(".doit-ref, .doit-ref-dead") || /%<\d+>/.test(el.textContent))
      )
    }
    if (!hasRef("[data-task-title]")) {
      set(pane.querySelector("#task-field-title"), text("[data-task-title]"))
    }
    // Description rides a hidden-when-empty row span (item 15.11) — fill the
    // textarea from it so the pane shows it instantly on selection, no round trip.
    if (!hasRef("[data-task-description]")) {
      set(pane.querySelector("#task-field-description"), text("[data-task-description]"))
    }

    // Progress slider (item 15.11): value + enabled state from the row, so it
    // reflects reality instantly. Value is the row's displayed % (branch =
    // computed); disabled when not a leaf, or the row says no progress rights.
    const prog = pane.querySelector("#task-field-progress")
    if (prog && prog !== document.activeElement) {
      const pv = row.getAttribute("data-task-progress")
      if (pv !== null) prog.value = pv
      const hasKids = !!li.querySelector(":scope > ul[id^='children-']")
      const canProgress = row.getAttribute("data-can-progress") === "true"
      prog.disabled = !canProgress || hasKids
      const readout = pane.querySelector("[data-progress-readout]")
      if (readout && pv !== null) readout.textContent = pv
    }

    // Branch-progress copy: the "Ignored — this task has subtasks." note and
    // the "Computed from children: N%" readout are server-gated on leaf-ness
    // (the `invisible` class on @task), so on a first selection of a branch
    // they stay hidden until the reply. Toggle them from the row's children
    // presence + computed % (data-task-progress = computed for a branch) so
    // they show instantly like the rest of the shell.
    const isBranch = !!li.querySelector(":scope > ul[id^='children-']")
    const cp = row.getAttribute("data-task-progress")
    const branchNote = pane.querySelector("[data-branch-note]")
    if (branchNote) branchNote.classList.toggle("invisible", !isBranch)
    const computedNote = pane.querySelector("[data-computed-note]")
    if (computedNote) {
      computedNote.classList.toggle("invisible", !isBranch)
      const cr = computedNote.querySelector("[data-computed-readout]")
      if (cr && cp !== null) cr.textContent = cp
    }
    const mpHint = pane.querySelector("[data-mp-hint]")
    if (mpHint) mpHint.classList.toggle("invisible", !isBranch)

    // The title attr always carries the priority ("Priority: high"). Either
    // pill may be display-pref-hidden (m02.04 §2.4) — skip its sync then,
    // the server render carries the truth.
    const priEl = row.querySelector("[data-pill='priority']")
    const pri = priEl ? (priEl.getAttribute("title") || "").replace("Priority: ", "") : ""
    if (pri) set(pane.querySelector("#task-field-priority"), pri)

    // Match the assignee option by its visible name (the pill shows "@name").
    const aSelect = pane.querySelector("#task-field-assignee")
    const aText = text("[data-pill='assignee'] [data-pill-text]")
    if (aSelect && row.querySelector("[data-pill='assignee']") && aSelect !== document.activeElement) {
      const name = aText.startsWith("@") ? aText.slice(1) : ""
      const opt = name
        ? [...aSelect.options].find((o) => o.textContent.trim() === name)
        : aSelect.options[0]
      if (opt && aSelect.value !== opt.value) aSelect.value = opt.value
    }

    // Sort block: visibility from children-presence, values from the li's
    // own sort attrs. The Inherit option's parenthetical corrects itself on
    // the server patch — text only, no layout shift.
    const sortBlock = pane.querySelector("[data-sort-block]")
    if (sortBlock) {
      const hasKids = !!li.querySelector(":scope > ul[id^='children-']")
      sortBlock.classList.toggle("invisible", !hasKids)
      // Point the (stable-id) form at the selected task so set_sort + SortRecall
      // target it during the in-flight window; the reply reconciles in place.
      const sortForm = sortBlock.querySelector("form")
      if (sortForm) {
        sortForm.dataset.taskId = this.id || ""
        const tid = sortForm.querySelector("[name='task_id']")
        if (tid) tid.value = this.id || ""
      }
      const mode = li.dataset.sort || ""
      const modeSel = sortBlock.querySelector("select[name='mode']")
      if (modeSel && modeSel !== document.activeElement && modeSel.value !== mode) {
        modeSel.value = mode
      }
      const rev = sortBlock.querySelector("input[name='reverse']")
      if (rev && rev !== document.activeElement) {
        const want = li.dataset.sortReverse === "true"
        if (rev.checked !== want) rev.checked = want
        const dis = mode === "" || mode === "manual"
        if (rev.disabled !== dis) rev.disabled = dis
      }
    }

    // Optimistic co-assignees (item 15.11): mirror the row's hidden co-seed
    // spans into a read-only list so co's show the instant the pane switches,
    // ahead of the server reply that fills the real interactive list below.
    // Read-only by design — the truthful, reorderable list is the hook's.
    const coOpt = pane.querySelector("#co-optimistic")
    const optList = coOpt && coOpt.querySelector("[data-co-opt-list]")
    if (optList) {
      const seeds = [...row.querySelectorAll("[data-co-seed]")]
      optList.innerHTML = ""
      seeds.forEach((s) => {
        const liEl = document.createElement("li")
        liEl.className = "flex items-center gap-2 text-sm"
        const av = document.createElement("span")
        av.className =
          "avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-5 h-5 text-[10px]"
        av.textContent = s.dataset.initials || ""
        av.style.backgroundImage = s.dataset.avatarBg || ""
        av.style.color = s.dataset.avatarFg || ""
        const nm = document.createElement("span")
        nm.className = "flex-1 min-w-0 truncate text-zinc-700 dark:text-zinc-200"
        nm.textContent = "@" + (s.dataset.name || "")
        liEl.appendChild(av)
        liEl.appendChild(nm)
        optList.appendChild(liEl)
      })
      coOpt.hidden = seeds.length === 0
    }
  },
}
window.DoitSelection = DoitSelection

// Client-owned initiative-editor visibility (UX_GUARDRAILS 6.5). Opening the
// editor is pure VIEW STATE: the pane (#initiative-editor-pane) is already
// server-rendered with #initiative-form pre-populated from the initiative, so
// revealing it loads nothing — no round trip. Mirrors DoitSelection: the flag
// lives on the client and the preserve-path `dom:` callbacks re-assert it across
// every patch (the server now always renders the pane hidden, since @editing_initiative?
// stays false). The form SUBMIT (update_initiative) and subtitle change
// (update_subtitle) remain real server writes — only open/close is client-side.
const DoitInitiativeEditor = {
  // `open` is a getter/setter backed by DoitState.editorOpen so editor
  // visibility has a single source of truth: the preserve-path `dom:` callbacks
  // (KeepRegistry.editor / "editor-signifier") and the immediate apply() below
  // both read the same value and stay consistent.
  get open() { return DoitState.editorOpen },
  set open(v) { DoitState.editorOpen = v },
  // Reveal the editor. Opening it deselects any task (the rail shows the editor
  // OR a task's Details OR Members — never editor + Details together).
  show() {
    if (window.DoitSelection) window.DoitSelection.clear()
    this.open = true
    this.apply()
  },
  // Hide the editor. `skipSelectionClear` is set when the caller is the
  // selection path itself (a task was just chosen) — clearing selection there
  // would undo the very selection that's closing the editor.
  close(opts = {}) {
    this.open = false
    if (!opts.skipSelectionClear && window.DoitSelection) window.DoitSelection.clear()
    this.apply()
  },
  // Toggle from the title affordance (item 6.7): a second activation closes the
  // pane. Reuses the same close()/show() paths as the rail/red-X close, so
  // DoitState.editorOpen, the `.editor-open` class, syncRail, and the preserve
  // path all stay consistent — no separate close logic to drift.
  toggle() {
    if (this.open) {
      this.close()
    } else {
      this.show()
    }
  },
  // Idempotent: only writes when the DOM disagrees, so re-applying converges
  // instead of looping. Drives the pane's `hidden`, the rail flyout
  // (via syncRail), and the title's dotted-underline signifier (shown only when
  // the editor is closed — the server can no longer toggle it).
  apply() {
    const ip = document.getElementById("initiative-editor-pane")
    if (ip && ip.hidden !== !this.open) ip.hidden = !this.open
    document.querySelectorAll("[data-edit-initiative]").forEach((el) => {
      el.classList.toggle("editor-open", this.open)
    })
    syncRail()
  },
}
window.DoitInitiativeEditor = DoitInitiativeEditor

// The right rail's mobile flyout state is view state (.03.07.20): `data-open`
// on #details-rail drives the overlay classes (Tailwind data-variants) and
// #pane-backdrop's visibility. Open = a task is selected or the initiative
// editor is showing — both client-known, so the flyout appears at the tap and
// the server patch just confirms the same attribute.
function syncRail() {
  const rail = document.getElementById("details-rail")
  if (!rail) return
  const open = !!(DoitSelection.id || DoitInitiativeEditor.open)
  if (rail.hasAttribute("data-open") !== open) rail.toggleAttribute("data-open", open)
  const backdrop = document.getElementById("pane-backdrop")
  if (backdrop && backdrop.hidden !== !open) backdrop.hidden = !open
}

// The one add-task form (UX_GUARDRAILS 6.5): opening, placing, and closing
// it never touches the server. It teleports between phx-update="ignore"
// slots, so no patch can disturb it mid-typing; create_task reads the two
// hidden inputs the client sets here.
// The placeholder gets a hint that Up/Down relocate the form (item 2.2): the
// base intent + the reposition signifier, so the keyboard affordance is visible.
const ADD_MOVE_HINT = "  (↑↓ to move)"
const DoitAddForm = {
  form() { return document.getElementById("add-task-form") },
  open(slot, parentId, afterId, placeholder) {
    const form = this.form()
    if (!form || !slot) return
    slot.appendChild(form)
    form.querySelector("[name='parent_id']").value = parentId || ""
    form.querySelector("[name='after_id']").value = afterId || ""
    const input = form.querySelector("[name='title']")
    input.dataset.basePlaceholder = placeholder
    input.placeholder = placeholder + ADD_MOVE_HINT
    input.value = ""
    input.focus()
  },
  openRoot() {
    this.open(document.getElementById("add-slot-root"), "", "", "New list / root task...")
  },
  openChild(taskId) {
    this.open(document.getElementById("add-slot-" + taskId), taskId, "", "New subtask...")
  },
  openSibling(taskId) {
    const li = document.getElementById("task-" + taskId)
    const parentLi = li && li.parentElement.closest("li[data-task-id]")
    this.open(
      document.getElementById("add-after-" + taskId),
      parentLi ? parentLi.dataset.taskId : "",
      taskId,
      "New task..."
    )
  },
  isOpen() {
    const form = this.form()
    const home = document.getElementById("add-task-home")
    return !!(form && home && form.parentElement !== home)
  },
  // The current slot is the form's parent — that's where it actually sits in
  // the tree, so the walk reads its real position rather than tracking state
  // that a teleport could desync.
  currentSlot() {
    const form = this.form()
    return this.isOpen() ? form.parentElement : null
  },
  // Every spot the form can land: the root slot, each task's first-child slot,
  // and each task's sibling-after slot — in document (visual) order. The slots
  // are `empty:hidden` when unoccupied, so we can't gate on offsetParent (it'd
  // hide all but the current one). Instead skip slots whose task sits in a
  // collapsed branch — there's no visible row to nest under or follow there.
  slots() {
    return [...document.querySelectorAll(
      "#add-slot-root, [id^='add-slot-'], [id^='add-after-']"
    )].filter((s) => {
      if (s.id === "add-slot-root") return true
      return !s.closest("ul.collapsed-peek")
    })
  },
  // Derive parent_id / after_id from a slot's id, mirroring openRoot/Child/Sibling.
  placeFor(slot) {
    const id = slot.id
    if (id === "add-slot-root") return {parentId: "", afterId: ""}
    if (id.startsWith("add-slot-")) return {parentId: id.slice("add-slot-".length), afterId: ""}
    const taskId = id.slice("add-after-".length)
    const li = document.getElementById("task-" + taskId)
    const parentLi = li && li.parentElement.closest("li[data-task-id]")
    return {parentId: parentLi ? parentLi.dataset.taskId : "", afterId: taskId}
  },
  // Walk the insertion point up (dir -1) or down (dir +1) one slot, carrying the
  // typed title along. Returns false at the ends so the caller can bonk.
  move(dir) {
    const form = this.form()
    const cur = this.currentSlot()
    if (!form || !cur) return false
    const slots = this.slots()
    const j = slots.indexOf(cur) + dir
    const next = slots[j]
    if (!next) return false
    const input = form.querySelector("[name='title']")
    const title = input.value
    const {parentId, afterId} = this.placeFor(next)
    next.appendChild(form)
    form.querySelector("[name='parent_id']").value = parentId || ""
    form.querySelector("[name='after_id']").value = afterId || ""
    input.value = title
    input.focus()
    form.scrollIntoView({block: "nearest"})
    return true
  },
  close() {
    const form = this.form()
    const home = document.getElementById("add-task-home")
    if (form && home) home.appendChild(form)
  },
}
window.DoitAddForm = DoitAddForm

// Keyboard ergonomics for the add-task form (item 2). Scoped to its title box,
// so these fire even while it's focused — the global TaskKeys handler suppresses
// itself in a field, so the adder owns its own keys here. Capture phase keeps it
// ahead of any field-level default, and the explicit target check means it never
// touches other inputs.
document.addEventListener("keydown", (e) => {
  const input = e.target
  if (!input || input.name !== "title" || !input.closest("#add-task-form")) return
  // Esc closes the adder and discards the typed title — no confirm (Esc edits no
  // text, so it's a safe exception to keyboard-suppression). It fires from inside
  // the box; the form isn't a modal, so it doesn't collide with the delete /
  // transfer Esc handlers (those only act on an open modal).
  if (e.key === "Escape") {
    e.preventDefault()
    DoitAddForm.close()
    return
  }
  // Up / Down walk the insertion point through the tree's child + sibling slots;
  // the typed title rides along. Left / Right stay with the text cursor.
  // preventDefault stops the caret from jumping to line start/end. A bonk marks
  // the ends of the walk.
  if (e.key === "ArrowUp" || e.key === "ArrowDown") {
    e.preventDefault()
    const moved = DoitAddForm.move(e.key === "ArrowUp" ? -1 : 1)
    if (!moved && window.DoitBonk) window.DoitBonk()
  }
}, true)

document.addEventListener("click", (e) => {
  if (e.target.closest("[data-add-root]")) return DoitAddForm.openRoot()
  const child = e.target.closest("[data-add-child]")
  if (child) return DoitAddForm.openChild(child.dataset.addChild)
  const sibling = e.target.closest("[data-add-sibling]")
  if (sibling) return DoitAddForm.openSibling(sibling.dataset.addSibling)
  if (e.target.closest("[data-add-cancel]")) DoitAddForm.close()

  // Generic client-side <details> drivers (the data-keep="open" toggle
  // listener records the state into DoitState.detailsOpen).
  const toggle = e.target.closest("[data-details-toggle]")
  if (toggle) {
    const d = document.getElementById(toggle.dataset.detailsToggle)
    if (d) d.open = !d.open
    if (d && d.open) {
      const focusable = d.querySelector("input, select, textarea")
      if (focusable) focusable.focus()
    }
    return
  }
  const closer = e.target.closest("[data-details-close]")
  if (closer) {
    const d = document.getElementById(closer.dataset.detailsClose)
    if (d) d.open = false
  }

  // Copy a task's positional index to the clipboard. The button is a child of
  // [data-task-row], so the row-click handler's interactive guard already skips
  // selection for this click — we just do the copy. navigator.clipboard needs a
  // secure context; fall back to a hidden textarea + execCommand otherwise.
  const copyIndex = e.target.closest("[data-copy-index]")
  if (copyIndex) {
    const text = copyIndex.dataset.copyIndex || ""
    copyToClipboard(text)
    flashCopied(copyIndex)
    return
  }
})

// Client-owned <details> open/closed (worklist 2 slice 2.3). A preserved
// <details> renders `data-keep="open"`; its expanded state is client truth in
// DoitState.detailsOpen (keyed by element id), re-asserted across patches by the
// KeepRegistry "open" applier. This delegated listener records every change —
// the sole recorder now that the KeepOpen hook is retired (worklist 2.4).
// `toggle` doesn't bubble, so it can't be caught in the normal (bubbling) phase
// from the document — but the CAPTURE phase reaches the target on the way down
// regardless of bubbling, so one capturing listener covers every such element,
// including ones re-added by a later patch.
document.addEventListener("toggle", (e) => {
  const d = e.target
  if (d && d.matches && d.matches("details[data-keep='open']") && d.id) {
    DoitState.detailsOpen[d.id] = d.open
  }
}, true)

// Close a popover menu (the Account + Hamburger <details data-menu>, plus the
// bell) when the user picks a navigation item inside it. Regression cause: a
// list<->detail hop is now a push_patch (not a full nav), and DoitState preserves
// <details open> across patches/navigations — so the menu no longer closes on its
// own when an item navigates; the "open" applier would re-open it on the
// destination. The summary toggle and inline controls (theme buttons) aren't
// links, so they keep working; only an actual navigation link (<a>) inside the
// menu closes it. Evict the preserved open-state too, so the preserve path leaves
// it shut on the destination.
document.addEventListener("click", (e) => {
  const link = e.target.closest("a")
  if (!link) return
  const menu = link.closest("details[data-menu]")
  if (!menu || !menu.id) return
  menu.open = false
  delete DoitState.detailsOpen[menu.id]
})

// Client-owned inner scroll position (worklist 2 slice 2.3.8). A scroll box
// renders `data-keep="scroll"`; its scrollTop is client truth in
// DoitState.scroll (keyed by element id), restored across a remove-and-re-add
// patch by the KeepRegistry "scroll" applier. Like `toggle`, the `scroll` event
// doesn't bubble, so a single CAPTURE-phase listener reaches every such target —
// including ones a later patch re-adds. We only record (cheap, idempotent
// store); the actual reconcile happens in the dom callbacks.
document.addEventListener("scroll", (e) => {
  const el = e.target
  if (el && el.matches && el.matches("[data-keep='scroll']") && el.id) {
    DoitState.scroll[el.id] = el.scrollTop
  }
}, true)

function copyToClipboard(text) {
  if (navigator.clipboard && window.isSecureContext) {
    navigator.clipboard.writeText(text).catch(() => fallbackCopy(text))
  } else {
    fallbackCopy(text)
  }
}

function fallbackCopy(text) {
  const ta = document.createElement("textarea")
  ta.value = text
  ta.setAttribute("readonly", "")
  ta.style.position = "fixed"
  ta.style.opacity = "0"
  document.body.appendChild(ta)
  ta.select()
  try { document.execCommand("copy") } catch (_) {}
  document.body.removeChild(ta)
}

// Briefly reveal a server-rendered-hidden "✓ Saved" span, then re-hide it
// (WL3 item 3.7, §6.7). The success ack where the effect is otherwise invisible
// (a debounced subtitle write, the viewer+ flip). Self-clearing on a fixed
// timeout, exactly like flashCopied — transient, rides the preserve path with
// no data-keep (the server always renders the span hidden). Reused by the
// subtitle-saved and viewer-plus-saved push_events routed through TaskKeys.
function showSavedTick(spanId) {
  const span = document.getElementById(spanId)
  if (!span) return
  span.hidden = false
  clearTimeout(span._tickTimer)
  span._tickTimer = setTimeout(() => { span.hidden = true }, 1200)
}
window.DoitSavedTick = showSavedTick

// Briefly swap the clipboard icon for a check to confirm the copy, then revert.
function flashCopied(btn) {
  const copyIcon = btn.querySelector("[data-copy-icon]")
  const copiedIcon = btn.querySelector("[data-copied-icon]")
  if (!copyIcon || !copiedIcon) return
  copyIcon.classList.add("hidden")
  copiedIcon.classList.remove("hidden")
  clearTimeout(btn._copyTimer)
  btn._copyTimer = setTimeout(() => {
    copiedIcon.classList.add("hidden")
    copyIcon.classList.remove("hidden")
  }, 1200)
}

// Optimistic task creation (item 15.15, UX_GUARDRAILS §6): pop a placeholder
// row in at submit, before the server trip — no reason to wait on the round
// trip to show the new task. It lands in a morphdom-managed container, so the
// create reply reconciles it away on its own: success renders the real row, a
// completion-flip swaps in the server's preview row, a cancel/reload drops it.
// Roll-up % up the tree is the server's job and arrives on that reply; only the
// bare row is instant. The flip-confirm decision stays server-side (no
// duplicated completion logic). An 8s timeout self-heals the rare case where no
// patch lands (dropped reply / a no-op error render) so a ghost never sticks.
let pendingRowSeq = 0
function buildPendingRow(title) {
  const li = document.createElement("li")
  li.id = "task-pending-" + ++pendingRowSeq
  li.setAttribute("data-pending-row", "")
  // No data-task-id / data-task-row: the row-click, drag, and key handlers all
  // skip it, so the transient placeholder is inert until the real row lands.
  li.className =
    "rounded border border-emerald-500/50 dark:border-emerald-500/40 bg-white dark:bg-zinc-900 is-saving"
  const row = document.createElement("div")
  row.className = "flex items-center gap-2 px-3 xl:px-5 2xl:px-6 pt-2 pb-6 min-w-[240px]"
  const name = document.createElement("span")
  name.className = "flex-1 min-w-0 truncate text-sm text-zinc-700 dark:text-zinc-200"
  name.textContent = title
  const note = document.createElement("span")
  note.className = "flex-none text-xs text-zinc-400 dark:text-zinc-500 italic"
  note.textContent = "Adding…"
  row.appendChild(name)
  row.appendChild(note)
  li.appendChild(row)
  setTimeout(() => li.remove(), 8000)
  return li
}
function placePendingRow(container, afterId, li) {
  if (afterId) {
    const slot = document.getElementById("add-after-" + afterId)
    const anchor = document.getElementById("task-" + afterId)
    const ref =
      slot && slot.parentElement === container ? slot.nextSibling :
      anchor && anchor.parentElement === container ? anchor.nextSibling : null
    container.insertBefore(li, ref) // null ref => append
  } else {
    container.insertBefore(li, container.firstChild) // top level / first child
  }
}
function insertPendingRow(parentId, afterId, title) {
  const li = buildPendingRow(title)
  if (parentId) {
    let ul = document.getElementById("children-" + parentId)
    if (!ul) {
      // First child of a leaf: no children list yet. Build a temp one to nest
      // in; morphdom swaps it for the real children-<id> ul on the reply.
      ul = document.createElement("ul")
      ul.id = "children-pending-" + parentId
      ul.className = "pl-1.5 sm:pl-6 space-y-1"
      const parentLi = document.getElementById("task-" + parentId)
      const slot = document.getElementById("add-slot-" + parentId)
      if (slot && slot.parentElement === parentLi) parentLi.insertBefore(ul, slot.nextSibling)
      else if (parentLi) parentLi.appendChild(ul)
      else return
    }
    placePendingRow(ul, afterId, li)
  } else {
    const tree = document.getElementById("task-tree")
    if (tree) placePendingRow(tree, afterId, li)
  }
}

// A brand-new leaf is always a 0% incomplete task, so the only completion flip
// it can cause is scenario 2: it lands under a parent that's currently complete
// (done), reopening that ancestor. That's client-derivable — the target parent's
// done state is in its rendered row (data-done) — so we predict it and open the
// instant #move-flip-confirm client-side (UX_GUARDRAILS 6.5), reusing the move's
// modal. The server's preview_create / @pending_action path stays the
// authoritative backstop for any flip the client didn't predict (stale DOM).
// A top-level create (no parent_id) can't reopen any visible ancestor, so it
// never predicts a flip.
function predictCreateFlip(parentId) {
  if (!parentId) return false
  const parentLi = document.getElementById("task-" + parentId)
  const row = parentLi && parentLi.querySelector(":scope > [data-task-row]")
  return !!(row && row.hasAttribute("data-done"))
}

// Push create_task ourselves (so we can carry confirmed:true). On success/flip
// the server's load_tree re-render reconciles the preview row away; on failure
// it surfaces a flash and the 8s preview-row timer self-heals.
function pushCreateTask(title, parentId, afterId, confirmed) {
  if (!window.DoitPush) return
  const payload = {title, parent_id: parentId || "", after_id: afterId || ""}
  if (confirmed) payload.confirmed = true
  window.DoitPush("create_task", payload)
}

// Rapid entry: clear the title after the submit is handled and stay focused, so
// consecutive adds need no clicks at all.
document.addEventListener(
  "submit",
  (e) => {
    if (e.target.id !== "add-task-form") return
    const form = e.target
    const input = form.querySelector("[name='title']")
    const title = input.value.trim()
    const parentId = form.querySelector("[name='parent_id']").value
    const afterId = form.querySelector("[name='after_id']").value
    const resetInput = () =>
      setTimeout(() => {
        input.value = ""
        input.focus()
      }, 0)

    if (!title) {
      resetInput()
      return
    }

    // Predicted completion flip (scenario 2): intercept the native phx-submit,
    // open the client confirm, and push ourselves only on Proceed. The preview
    // row still goes in immediately (the task SHOWS UP while the modal decides,
    // §8.20 parity with a held move/cascade). Suppressed → commit straight
    // through without the modal.
    if (predictCreateFlip(parentId) && !createFlipSuppressed()) {
      e.preventDefault()
      e.stopImmediatePropagation() // stop LiveView's own phx-submit push
      insertPendingRow(parentId, afterId, title)
      openCreateFlipConfirm({title, parentId, afterId})
      resetInput()
      return
    }

    // No predicted flip: let the native phx-submit fire; splice the preview row.
    insertPendingRow(parentId, afterId, title)
    resetInput()
  },
  true // capture phase: run before LiveView's bubble-phase phx-submit handler
)

// Completion-flip suppression shares the move's localStorage key + ConfirmSkips
// class ("completion-flip"), so "don't ask again" set from a move also silences
// the create flip (and vice-versa) — they're the same confirm class.
const CREATE_FLIP_SKIP_KEY = "doit:confirm-skip:completion-flip"
const createFlipSuppressed = () => {
  try { return localStorage.getItem(CREATE_FLIP_SKIP_KEY) === "1" } catch (_e) { return false }
}

// Reuse #move-flip-confirm for the create flip: same scenario-2 copy, same
// modal. Stash the create params on the modal so the Proceed handler (below)
// can re-submit with confirmed:true. Cancel drops the optimistic preview row.
function openCreateFlipConfirm(params) {
  const modal = document.getElementById("move-flip-confirm")
  if (!modal) {
    // No modal — fall back to the server path: push unconfirmed and let the
    // server raise its backstop confirm.
    pushCreateTask(params.title, params.parentId, params.afterId, false)
    return
  }
  modal.dataset.createFlip = "1"
  modal.dataset.createTitle = params.title
  modal.dataset.createParentId = params.parentId || ""
  modal.dataset.createAfterId = params.afterId || ""
  openMoveFlipConfirm({scenario: 2, titles: []})
}

// Drop the optimistic preview row(s) — the create the modal was deciding never
// committed. (They also self-expire at 8s; remove now for an instant response.)
function dropPendingRows() {
  document.querySelectorAll("[data-pending-row]").forEach((el) => el.remove())
}

// Pane visibility is pure VIEW STATE, fully client-side (.03.07.08,
// UX_GUARDRAILS 6.5) — no round trip gates open or close. The editor pane is
// already server-rendered (hidden) with #initiative-form pre-populated, so the
// title click reveals it instantly; selecting a task closes it (DoitSelection)
// and opening it deselects any task (DoitInitiativeEditor.show). Only real
// writes — the form submit (update_initiative) and the subtitle change
// (update_subtitle) — still touch the server.
document.addEventListener("click", (e) => {
  // Click the initiative title / subtitle → toggle the editor (item 6.7): open
  // if closed, close if already open. No DoitPush.
  if (e.target.closest("[data-edit-initiative]")) {
    DoitInitiativeEditor.toggle()
    return
  }
  // The editor's own close (red X) → hide the editor.
  if (e.target.closest("[data-close-initiative]")) {
    DoitInitiativeEditor.close()
    return
  }
  // The mobile flyout close (rail X + backdrop) shuts whichever pane is open:
  // the editor and/or a task's Details. Closing the editor is client-only; if a
  // task was selected, tell the server so it drops the selection presence (the
  // row-click path's close_task equivalent for this control).
  if (e.target.closest("[data-close-panel]")) {
    const hadSelection = !!DoitSelection.id
    // close() also clears the selection (skipSelectionClear is unset).
    DoitInitiativeEditor.close()
    if (hadSelection && window.DoitPush) window.DoitPush("close_task", {})
    return
  }
  // The desktop Task-details pane "X" (lg:+) — client-instant like the
  // row-deselect path: clear the selection AT THE CLICK (syncPaneSkeleton hides
  // the pane) instead of waiting for the server's hidden= re-render, then push
  // close_task so the server drops the selection presence. The button carries
  // no native phx-click, so this is the single push; a real <button> gives
  // Enter/Space parity for free.
  if (e.target.closest("[data-close-task]")) {
    const hadSelection = !!DoitSelection.id
    DoitSelection.clear()
    if (hadSelection && window.DoitPush) window.DoitPush("close_task", {})
  }
})

// The title affordance is a role="button" wrapper (an <h1> can't live in a real
// <button>), so it needs explicit keyboard activation: Enter / Space toggle the
// editor, mirroring the click path above. preventDefault on Space stops the page
// from scrolling.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Enter" && e.key !== " ") return
  const trigger = e.target.closest("[data-edit-initiative][role='button']")
  if (!trigger) return
  e.preventDefault()
  DoitInitiativeEditor.toggle()
})

// Password peek toggle (WL6 6.1): a global delegated click so it works on the
// dead controller views (login / register — no LiveView socket, so a phx-hook
// never mounts) as well as any live page. Keys off data-password-toggle, looks
// up the paired input via data-input-id, swaps its type, flips aria-pressed +
// the accessible name, and toggles which icon (eye vs. eye-slash) shows.
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-password-toggle]")
  if (!btn) return
  const input = document.getElementById(btn.dataset.inputId)
  if (!input) return
  const showing = input.type === "text"
  input.type = showing ? "password" : "text"
  const eye = btn.querySelector(".password-eye")
  const eyeSlash = btn.querySelector(".password-eye-slash")
  if (eye) eye.classList.toggle("hidden", !showing)
  if (eyeSlash) eyeSlash.classList.toggle("hidden", showing)
  btn.setAttribute("aria-pressed", showing ? "false" : "true")
  btn.setAttribute("aria-label", showing ? "Show password" : "Hide password")
})

// Theme controls on DEAD views (login / register — no LiveView socket, so the
// desktop group's phx-click JS commands never bind and the mobile ThemeCycle
// hook never mounts; clicking theme there did NOTHING). A global delegated
// click — registered at module load, mirroring the password-peek toggle above —
// makes the VISUAL theme apply connect-independent: it dispatches phx:set-theme,
// which the window listener in root.html.heex applies instantly (data-theme +
// localStorage). On a LIVE page the group's own phx-click still runs and
// persists via the set_theme push; this extra dispatch is idempotent (same
// theme) so the live behavior is unchanged. Persistence stays live-only — only
// the visual apply needs to be connect-independent.
const THEME_CYCLE_ORDER = ["system", "light", "dark"]
function dispatchSetTheme(theme) {
  if (theme) window.dispatchEvent(new CustomEvent("phx:set-theme", {detail: {theme}}))
}
document.addEventListener("click", (e) => {
  // Desktop group buttons carry their target theme on data-phx-theme.
  const groupBtn = e.target.closest("[data-phx-theme]")
  if (groupBtn) {
    dispatchSetTheme(groupBtn.dataset.phxTheme)
    return
  }
  // Mobile single-icon cycle (system → light → dark). Defer to the ThemeCycle
  // hook once it's mounted (it marks its element) so a live page never double-
  // cycles; this only fires as the dead-view / pre-connect fallback.
  const cycle = e.target.closest("#theme-cycle")
  if (cycle && !cycle.dataset.themeHooked) {
    const cur = localStorage.getItem("phx:theme") || "system"
    const next = THEME_CYCLE_ORDER[(THEME_CYCLE_ORDER.indexOf(cur) + 1) % THEME_CYCLE_ORDER.length]
    dispatchSetTheme(next)
    // Mirror the hook's icon sync so the single icon updates immediately.
    cycle.querySelectorAll("[data-theme-icon]").forEach((s) => {
      s.classList.toggle("hidden", s.dataset.themeIcon !== next)
    })
  }
})

// Notifications "mark read" (§6.7): the "Mark all read" button AND opening the
// bell both mark notifications read, but they rode JS.push("mark_notifications_read")
// — no optimistic clear (the unread state lingered until the server round-trip)
// and JS.push is skipped by the §6.8 dead-window interceptor (a pre-connect
// click vanished). Now: optimistically clear the unread affordances AT THE CLICK
// — the bell's red dot, each row's unread dot, the bold emphasis, and the "Mark
// all read" button — then push via window.DoitPush so the dead-window queue
// captures it. The server re-render reconciles authoritatively, re-asserting
// truth if it disagrees (MUST NOT LIE).
function clearNotifUnread() {
  document.querySelectorAll("[data-notif-dot], [data-notif-unread-dot], [data-notif-mark-read]")
    .forEach((el) => { el.hidden = true })
  // Un-bold each notification row to the muted "read" treatment (mirrors the
  // server's read_at class branch; the patch re-renders the same).
  document.querySelectorAll("[data-notif-link]").forEach((el) => {
    el.classList.remove("font-medium", "text-zinc-800", "dark:text-zinc-100")
    el.classList.add("text-zinc-500", "dark:text-zinc-400")
  })
}
document.addEventListener("click", (e) => {
  if (!e.target.closest("[data-notif-mark-read], [data-notif-bell]")) return
  clearNotifUnread()
  if (window.DoitPush) window.DoitPush("mark_notifications_read", {})
})

// Row clicks: selection toggles instantly client-side; the server event only
// drives the Details pane. Pills (data-pill) keep their own phx-click (pane
// data load) and never toggle the selection closed; their field focus is pure
// view state, done right here (.03.07.17) — on a first-ever selection the
// pane isn't mounted yet, so the focus parks in DoitPendingFocus and
// syncPaneSkeleton lands it when the pane arrives.
document.addEventListener("click", (e) => {
  const row = e.target.closest("[data-task-row]")
  // Selection + the optimistic pane fill are client-only (DoitSelection) and
  // must work even before the LiveView connects (slow on longpoll) — so DON'T
  // gate on window.DoitPush. Only the server pushes below need it, and the
  // TaskKeys hook replays select_task for the live selection once it mounts.
  if (!row) return
  // Interactive children (toggle, collapse, pills, drag handle) own their
  // clicks; pills additionally select without toggling. The check must stay
  // inside the row — ancestors (children <ul>s, the page root) carry hooks.
  const interactive = e.target.closest("button, a, form, [phx-hook]")
  if (interactive && interactive !== row && row.contains(interactive)) {
    const pill = e.target.closest("[data-pill]")
    if (pill) {
      const li = row.closest("li[data-task-id]")
      if (li) DoitSelection.set(li.dataset.taskId)
      const field = document.getElementById("task-field-" + pill.dataset.pill)
      if (field && !field.disabled) {
        field.focus()
        field.scrollIntoView({block: "nearest"})
      } else if (!field) {
        window.DoitPendingFocus = "task-field-" + pill.dataset.pill
      }
    }
    return
  }
  const li = row.closest("li[data-task-id]")
  if (!li) return
  const id = li.dataset.taskId
  if (DoitSelection.id === id) {
    DoitSelection.clear()
    if (window.DoitPush) window.DoitPush("close_task", {})
  } else {
    DoitSelection.set(id)
    if (window.DoitPush) window.DoitPush("select_task", {id: id})
  }
})

// Pink-on-interaction wiring for the click / change write paths.
document.addEventListener("click", (e) => {
  // Pending-confirm pinking is server-rendered (pink = "maybe write"): while a
  // confirm modal is open the rows at stake hold the hue via the
  // pending_saving_ids assign, so it survives re-renders; Cancel clears it and
  // Proceed keeps it through the write. Nothing to do client-side here.
  // (Task deletion's confirm is the exception — fully client-side, .03.07.15,
  // handled by the #delete-confirm block below.)
  // Completion toggle (leaf or branch) — pink the toggled row + its subtree +
  // the ancestor chain whose progress / status recomputes; the operated row
  // itself flips FULLY optimistically (.03.07.22): checkbox, done styling,
  // and its bar, at the click. The push replies like move_task: ok: false
  // reverts, committed: true releases, committed: false (a confirm modal is
  // deciding) HOLDS the flip via the guard net until cancelled/resolved (6.6).
  const toggle = e.target.closest("[data-complete-toggle]")
  if (toggle) {
    const li = toggle.closest(SAVING_ROW)
    if (!li) return
    const subtree = savingSubtree(li)
    const ancestors = savingAncestors(li)
    markSaving([...subtree, ...ancestors])
    // Descendants (a branch cascade's subtree, below the toggled node) stay
    // indeterminate — item 3's client prediction is scoped to the ANCESTOR
    // chain only. The operated row's own bar is set optimistically below.
    markRecomputing(subtree.slice(1))
    const ev = toggle.dataset.toggleEvent
    if (!ev || !window.DoitPush) return
    // Predicted, not indeterminate (m03.02 item 3): a toggle/cascade snaps
    // its whole subtree to a known 100/0, so the ancestor chain's new
    // progress + done-state are both fully computable — paint them instead
    // of the gradient. Snapshot each ancestor's PRE-paint values first:
    // unlike the progress slider (a plain form round trip), this write can
    // be REJECTED (ok:false, no assign change -> no corrective patch) or
    // CANCELLED (the branch-cascade confirm never touches the server at
    // all) — so these ride the SAME pending-toggle hold as the operated
    // row's own flip and get reverted alongside it (revertPendingToggle),
    // not new reconciliation machinery. Painted only past this point (not
    // above, alongside markSaving/markRecomputing) so it never paints
    // without also being wired into that hold — the CSS-only hue above is
    // safe to paint speculatively (self-heals via markSaving's own timer
    // regardless); a real number/done-state is not.
    const newDone = !(toggle.getAttribute("aria-pressed") === "true")
    const predicted = predictAncestors(ancestors, li, newDone ? 100 : 0, newDone)
    const ancestorRevert = predicted.map((p) => ({
      row: p.row,
      prevProgress: rowBarValue(p.li),
      prevDone: rowDone(p.li),
    }))
    predicted.forEach((p) => {
      setRowBar(p.row, p.progress)
      p.row.toggleAttribute("data-done", p.done)
      const ancestorToggle = p.row.querySelector("[data-complete-toggle]")
      if (ancestorToggle) {
        ancestorToggle.setAttribute("aria-pressed", String(p.done))
        ancestorToggle.setAttribute("aria-label", p.done ? "Reopen task" : "Mark task completed")
      }
    })
    // Flip the operated row optimistically FIRST (6.6) — the change shows
    // before any confirm decides; the held handle survives until settled.
    applyToggleOptimism(li, toggle)
    window.DoitPendingToggle = {...window.DoitPendingToggle, ancestorRevert}
    // A branch cascade (complete / reopen this branch AND all subtasks) asks
    // first, unless suppressed. The confirm opens CLIENT-SIDE (#cascade-confirm,
    // UX_GUARDRAILS 6.5) — title + verb are client-known — holding the flip
    // while it decides. A leaf toggle (toggle_complete) never asks.
    const cascade = ev === "cascade_complete" || ev === "cascade_incomplete"
    if (cascade && !cascadeConfirmSuppressed() && openCascadeConfirm(li, ev)) return
    pushToggleCommit(ev, li)
    return
  }
  // Cascade-sort to all descendants — pink the whole subtree of the selected branch.
  if (e.target.closest("[data-saving-subtree]")) {
    const li = selectedLi()
    if (li) markSaving(savingSubtree(li))
  }
})

document.addEventListener("change", (e) => {
  // Settings: task-numbering style (WL3 item 3.7, §6.7). Re-deriving every
  // node's positional label in JS would duplicate Tasks.Index, so instead of a
  // true optimistic relabel we show a transient "saving" hue across the index
  // spans; the re-label patch strips it (the server never emits is-saving) and
  // markSaving's safety timer covers a dropped reply. No data-keep needed —
  // same lifecycle as every other saving-hue path.
  if (e.target.id === "index-style") {
    // Pink the index spans when they exist (style→style / style→none). In the
    // none→style direction there are no spans yet (the server renders one only
    // when the style isn't "none"), so fall back to the always-present task rows
    // so the relabel still cues in flight. Either set is stripped by the patch.
    const spans = [...document.querySelectorAll("#task-tree [data-task-index]")]
    markSaving(spans.length ? spans : [...document.querySelectorAll("#task-tree [data-task-row]")])
    return
  }
  // Settings: progress calc (WL3 item 3.7, §6.1/§6.7). A whole-tree % recompute
  // round trips before any bar changes — acknowledge it's in flight by pinking
  // + setting every row's bar indeterminate (the same "% genuinely in flight"
  // treatment), cleared by the authoritative recompute patch. Don't fake a
  // number — markRecomputing shows the gradient + "…" until the real %s land.
  if (e.target.id === "progress-calc") {
    const rows = [...document.querySelectorAll("#task-tree li[data-task-id]")].map(savingRowOf)
    markSaving(rows)
    markRecomputing(rows)
    return
  }
  // Settings: viewer+ toggle (WL3 item 3.7, §6.7). Flipping it re-evaluates
  // edit-ability across the tree on the round trip. In-flight signifier: disable
  // the checkbox + pink the tree rows whose edit affordances change; the server
  // replies with a "viewer-plus-saved" push_event (handled in the TaskKeys hook)
  // that re-enables the box and flashes a saved tick — that re-enable IS the
  // success ack. A safety timer re-enables on a dropped reply so it never sticks.
  if (e.target.name === "viewer_plus") {
    e.target.disabled = true
    markSaving([...document.querySelectorAll("#task-tree li[data-task-id]")].map(savingRowOf))
    clearTimeout(e.target._vpTimer)
    e.target._vpTimer = setTimeout(() => { e.target.disabled = false }, 8000)
    return
  }
  // Sort menu — pink the resorted children of the selected branch.
  if (e.target.closest("[data-saving-children]")) {
    const li = selectedLi()
    if (li) markSaving(savingChildren(li))
    return
  }
  // Details attribute fields — pink the edited row; manual progress rolls
  // up, so its ancestors pink too (§8.18.3 finding: progress writes were
  // missing from this scope entirely). Priority / assignee don't roll up.
  // Title / description stay excluded (no roll-up, instant echo).
  const pinkFields = [
    "task-field-priority",
    "task-field-assignee",
    "task-field-progress",
  ]
  if (pinkFields.includes(e.target.id)) {
    const li = selectedLi()
    if (!li) return
    const rollup = e.target.id === "task-field-progress"
    if (rollup) {
      const ancestors = savingAncestors(li)
      markSaving([savingRowOf(li), ...ancestors])
      // Predicted, not indeterminate (m03.02 item 3): the edited leaf's exact
      // new value is already known, so paint each ancestor's real rolled-up
      // number — replaces the indeterminate gradient entirely for this path
      // (still pinked via markSaving above, signaling "in flight"; just no
      // longer "we don't know the number"). This write is a plain LiveView
      // form round trip (phx-change="update_task"), not a reply-gated push,
      // so a misprediction self-heals on the very next patch with no revert
      // bookkeeping needed — same guarantee applyRowEcho already relies on
      // for this exact field.
      const predicted = predictAncestors(ancestors, li, Number(e.target.value), rowDone(li))
      predicted.forEach((p) => setRowBar(p.row, p.progress))
    } else {
      markSaving([savingRowOf(li)])
    }
  }
})

// Client-side view-state reveals (WL3 3.2, §6.5/§6.7). Two checkbox buckets,
// both riding the preserve path so the optimistic state survives patches and
// reconnect:
//
//  - Group-by-Initiative (Assigned view) is pure arrangement — flip the
//    wrapper's data-grouped at the click for an instant client-side reflow (the
//    CSS shows/hides the always-rendered group headers + row subtitles); the
//    phx-click round-trip only persists the pref and reconciles.
//  - The reveal toggles (show-completed / show-archived-hidden / show-hidden)
//    are server-gated (rows filtered out of the DOM) — keep the round-trip but
//    acknowledge at the click: record the optimistic tick and raise aria-busy +
//    the trailing spinner, held until the server's re-render agrees. We never
//    reveal rows ourselves (no phantom rows).
//
// `change` (not `click`) so a click on the <label> — which toggles the box
// natively without an input-targeted click — is caught too; it fires once,
// after the checked state has settled, so box.checked is the optimistic value.
// The phx-click on each box still fires (the server gets the event); this only
// adds the client-owned acknowledgement on top.
document.addEventListener("change", (e) => {
  const box = e.target
  if (!box || !box.matches) return
  if (box.matches("input[data-group-wrap]")) {
    const wrapId = box.dataset.groupWrap
    DoitState.assignedGrouped[wrapId] = box.checked
    const wrap = document.getElementById(wrapId)
    if (wrap) wrap.setAttribute("data-grouped", String(box.checked))
    return
  }
  if (box.matches("input[data-keep='reveal-toggle']")) {
    DoitState.revealInflight[box.id] = box.checked
    box.setAttribute("aria-busy", "true")
    // Connect-independent spinner (WL4.3, §6.7): the server-rendered spinner CSS
    // keys off LiveView's phx-click-loading, which isn't added pre-connect (or in
    // the dead window). This client class — set here at the click, cleared by the
    // "reveal-toggle" applier alongside aria-busy — drives the same spinner so it
    // shows at the gesture too. Mirrors the phx-click-loading rule (app.css).
    box.classList.add("doit-reveal-busy")
    return
  }
})

// Archive-on-completion banner dismiss (WL3 3.2, §6.5): hide it the instant the
// X is clicked — pure view state — and let the existing phx-click reconcile
// (the server drops show_archive_prompt, removing the element). The flag keeps
// it hidden across any patch that lands before that reply; onPatchEnd clears the
// flag once the element is gone.
document.addEventListener("click", (e) => {
  if (!e.target.closest("[data-archive-dismiss]")) return
  DoitState.archivePromptDismissed = true
  const banner = document.getElementById("archive-prompt")
  if (banner) banner.hidden = true
})

// Optimistic row echo (UX_GUARDRAILS 6.2): a pane edit tells us exactly what
// the selected row will show after the write, so the row updates at the
// keystroke. The server patch re-renders the same values (no flicker) and a
// rejected write restores the truth. Roll-up math (ancestors, branch %) is
// never predicted — the saving hue covers that window.
//
// Extracted so the keyboard P/A step (TaskKeys.kbd_adjust) can reuse it: it
// sets the pane <select>'s value then calls window.DoitRowEcho(field) DIRECTLY
// — not via a synthetic `input` event, which would also trip the form's
// phx-change and double-push update_task alongside kbd_adjust.
function applyRowEcho(t) {
  if (!t) return
  const li = selectedLi()
  const row = li && li.querySelector(":scope > [data-task-row]")
  if (!row) return
  switch (t.id) {
    case "task-field-title": {
      const el = row.querySelector("[data-task-title]")
      if (el) el.textContent = t.value
      return
    }
    case "task-field-description": {
      const el = row.querySelector("[data-task-description]")
      if (!el) return
      el.textContent = t.value
      el.hidden = t.value === ""
      return
    }
    case "task-field-priority": {
      const pill = row.querySelector("[data-pill='priority']")
      if (!pill) return
      // Priority always has a value — the pill stays "set" and shows
      // "normal" too. data-priority drives the chip color (app.css), so the
      // optimistic echo recolors by flipping one attribute (m02.07 item 1.6).
      pill.toggleAttribute("data-pill-set", true)
      pill.setAttribute("data-priority", t.value)
      pill.textContent = t.value
      pill.title = "Priority: " + t.value
      return
    }
    case "task-field-assignee": {
      const pill = row.querySelector("[data-pill='assignee']")
      const span = pill && pill.querySelector("[data-pill-text]")
      if (!span) return
      const opt = t.value ? t.options[t.selectedIndex] : null
      const name = opt ? opt.textContent.trim() : ""
      pill.toggleAttribute("data-pill-set", !!name)
      span.textContent = name ? "@" + name : ""
      // Any selectable assignee is a current member — clear an ex-member strike.
      span.classList.remove("line-through")
      pill.title = name ? "Assignee: @" + name : "Unassigned"
      // Mirror the avatar from the option's data attrs (same derivation as
      // the server's avatar component).
      const avatar = pill.querySelector("[data-pill-avatar]")
      if (avatar) {
        avatar.hidden = !opt
        if (opt) {
          avatar.textContent = opt.dataset.initials || ""
          avatar.style.backgroundImage = opt.dataset.avatarBg || ""
          avatar.style.color = opt.dataset.avatarFg || ""
        }
        // Keep the online dot honest for the optimistic assignee too.
        avatar.dataset.assigneeId = t.value || ""
        const online = new Set(((window.DoitPresence && window.DoitPresence.online) || []).map(String))
        avatar.classList.toggle("chip-online", !!t.value && online.has(t.value))
      }
      // Promoting a current co-assignee to PRIMARY drops them from the co-list —
      // you can't be both (the server does the same in update_task via
      // drop_co_assignee). The co-list is phx-update="ignore", so the assignee
      // patch never re-renders it; this optimistic removal is the live update
      // (a re-selection reloads the canonical list). Mirrors the CoAssignees
      // hook's own remove.
      if (t.value) dropCoAssigneeRow(t.value)
      return
    }
    case "task-field-progress": {
      const readout = document.querySelector("#task-editor-pane [data-progress-readout]")
      if (readout) readout.textContent = t.value
      // The slider only writes a leaf's bar; a done leaf displays 100
      // regardless of the manual value, so leave it to the server.
      const done = row.querySelector("[data-complete-toggle][aria-pressed='true']")
      if (!done) setRowBar(row, t.value)
      return
    }
  }
}
document.addEventListener("input", (e) => applyRowEcho(e.target))
// Reused by the colocated TaskKeys hook for the keyboard P/A step (can't import).
window.DoitRowEcho = applyRowEcho

// ---------------------------------------------------------------------------
// Cross-reference (%-notation) READ path — Wave 1: render + navigate.
//
// Titles/descriptions are STORED with resolved tokens `%<id>` (ASCII angle
// brackets) and the server renders that raw string straight into
// [data-task-title] / [data-task-description] — HEEx {}-interpolation escapes
// the `<`/`>`, so the browser parses a literal text node (never a tag) and
// el.textContent reads back the exact token. Here we turn each token into a
// live link labelled with the referenced task's CURRENT tree number, and a click
// selects + scrolls to it. Pure `segments()` (refs.js) does the parse; the DOM is
// the sole source of truth for id -> label (read live from each row's
// [data-copy-index]), so a re-number is reflected with no server round trip.
//
// Idempotent + morphdom-safe: a server patch RESETS a changed element back to the
// raw token text (our nodes wiped), and the tree hook re-runs the render; an
// unchanged element keeps our nodes and only has its labels refreshed in place.
// Styling rides Tailwind utilities written as literal strings so the
// `@source "../js"` scan generates them (no app.css edit).
const REF_LINK_CLASS =
  "doit-ref text-emerald-700 dark:text-emerald-400 hover:underline decoration-dotted underline-offset-2 cursor-pointer"
const REF_DEAD_CLASS = "doit-ref-dead text-zinc-400 dark:text-zinc-500 cursor-default"

// id -> label ("1.5.1") for every row in the tree, read from each row's OWN
// [data-copy-index] (descendant rows carry their own, so bind each label to the
// nearest enclosing li[data-task-id]). Empty when Initiative numbering is off.
function buildRefLabelMap() {
  const map = new Map()
  document.querySelectorAll("[data-copy-index]").forEach((el) => {
    const li = el.closest("li[data-task-id]")
    if (li) map.set(Number(li.dataset.taskId), el.getAttribute("data-copy-index"))
  })
  return map
}

// WRITE-path resolvers (Wave 2) — the reverse of buildRefLabelMap, read live
// from the SAME [data-copy-index] rows so a re-number needs no round trip.
// Labels are unique per tree (positional dotted numbers), so label -> id is a
// function. Both build a fresh map per call: a pane title/description carries a
// handful of refs, so the O(rows) scan per ref is negligible and keeps the DOM
// the single source of truth.
//
//   resolveRefPath("1.5") -> id | null   (label -> id; used by transformForSave
//                                          to id-anchor %path on blur/save)
//   refLabelOf(id)        -> "1.5" | null (id -> label; used by rehydrate to
//                                          show %label in the edit box)
function buildRefPathMap() {
  const map = new Map()
  document.querySelectorAll("[data-copy-index]").forEach((el) => {
    const li = el.closest("li[data-task-id]")
    if (li) map.set(el.getAttribute("data-copy-index"), Number(li.dataset.taskId))
  })
  return map
}
function resolveRefPath(path) {
  const id = buildRefPathMap().get(path)
  return id == null ? null : id
}
function refLabelOf(id) {
  const label = buildRefLabelMap().get(id)
  return label == null ? null : label
}

// The DOM node for one `%<id>` token, given a prebuilt id->label map:
//   * resolvable label     -> clickable <a> showing the number (e.g. "1.5.1")
//   * live row, no label   -> clickable <a> showing "↗"  (numbering off)
//   * unresolved (no row)  -> muted, inert <span> showing "%?"
// The raw id is never surfaced to the reader.
function buildRefNode(id, map) {
  const label = map.has(id) ? map.get(id) : null
  const live = !!document.getElementById("task-" + id)
  if (label != null || live) {
    const a = document.createElement("a")
    a.className = REF_LINK_CLASS
    a.dataset.taskId = String(id)
    a.setAttribute("role", "link")
    a.textContent = label != null ? label : "↗"
    return a
  }
  const span = document.createElement("span")
  span.className = REF_DEAD_CLASS
  span.dataset.taskId = String(id)
  span.title = "Referenced task not found"
  span.textContent = "%?"
  return span
}

// Render one [data-task-title]/[data-task-description] from its RAW text.
// Already-rendered elements (they hold our nodes, so textContent is no longer the
// raw token string) are NOT re-parsed — we only refresh each ref's label in place
// so numbers stay live across re-orders. Ref-less prose is left as the server's
// text node, untouched.
function renderRefEl(el, map) {
  if (el.querySelector(".doit-ref, .doit-ref-dead")) {
    el.querySelectorAll(".doit-ref, .doit-ref-dead").forEach((node) => {
      const fresh = buildRefNode(Number(node.dataset.taskId), map)
      if (
        fresh.tagName !== node.tagName ||
        fresh.className !== node.className ||
        fresh.textContent !== node.textContent
      ) {
        node.replaceWith(fresh)
      }
    })
    return
  }
  const segs = segments(el.textContent)
  if (!segs.some((s) => s.type === "ref")) {
    // No refs, but escapes still resolve at render time (\% → %, \\ → \). Only
    // touch the DOM when that actually changes the text, so ref-less, escape-less
    // prose stays the server's untouched text node (the fast path).
    const resolved = segs.map((s) => s.value).join("")
    if (resolved !== el.textContent) el.textContent = resolved
    return
  }
  const frag = document.createDocumentFragment()
  segs.forEach((s) => {
    frag.appendChild(
      s.type === "text" ? document.createTextNode(s.value) : buildRefNode(s.id, map)
    )
  })
  el.replaceChildren(frag)
}

// Dashboard list-mode Initiative cards (name/subtitle/description) carry the
// STORED tokens but have NO tree loaded, so a `%<id>` can't resolve to a number
// here — and a card's refs belong to ITS OWN initiative, never whichever one is
// open, so resolving against the loaded tree would be wrong anyway. Rather than
// leak the raw token, render each ref as a neutral, inert "↗" glyph ("Linked
// task"); the detail view resolves it to the live number in full. The glyph
// never changes, so once rendered the element is left alone (idempotent; a
// server patch resets it to raw text and we re-parse). Backlog: real numbers on
// cards via a server-side resolve.
const REF_CARD_CLASS = "doit-ref-card text-emerald-600 dark:text-emerald-400 cursor-default"
function renderCardRefEl(el) {
  if (el.querySelector(".doit-ref-card")) return
  const segs = segments(el.textContent)
  if (!segs.some((s) => s.type === "ref")) {
    // No refs, but escapes still resolve (\% → %, \\ → \); leave escape-less text
    // as the server's untouched node.
    const resolved = segs.map((s) => s.value).join("")
    if (resolved !== el.textContent) el.textContent = resolved
    return
  }
  const frag = document.createDocumentFragment()
  segs.forEach((s) => {
    if (s.type === "text") {
      frag.appendChild(document.createTextNode(s.value))
    } else {
      const span = document.createElement("span")
      span.className = REF_CARD_CLASS
      span.title = "Linked task"
      span.textContent = "↗"
      frag.appendChild(span)
    }
  })
  el.replaceChildren(frag)
}

// Re-render every ref-bearing surface in `root` (defaults to the whole
// document): task titles/descriptions AND comment/chat message bodies (Wave 3),
// initiative header fields (Wave 5), plus the neutral card glyph for dashboard
// cards. ONE renderer over every surface — identical parse logic (segments), so
// a `%<id>` token renders consistently wherever it appears. Cheap + idempotent,
// so it's safe to re-run after every tree patch, comment-list refresh, chat
// message, or dashboard update.
function renderAllRefs(root) {
  const map = buildRefLabelMap()
  const scope = root || document
  scope
    .querySelectorAll(
      "[data-task-title], [data-task-description], [data-comment-body], [data-chat-body], [data-initiative-subtitle-body], [data-initiative-description-body]"
    )
    .forEach((el) => renderRefEl(el, map))
  // [data-card-ref-field] (5.10.3): the same label-less card treatment for
  // non-initiative surfaces with no tree loaded — e.g. /assigned task titles.
  scope
    .querySelectorAll("[data-initiative-card-field], [data-card-ref-field]")
    .forEach((el) => renderCardRefEl(el))
}
// Back-compat alias (the Wave 1/2 name) + the Wave 3 canonical name, both
// pointing at the unified renderer so the colocated .Chat hook (a separate
// bundle, no module scope) can drive it via window.
window.DoitRenderTaskRefs = renderAllRefs
window.DoitRenderRefs = renderAllRefs
// Resolve a user-typed body (`%label`) to its stored/broadcast token form
// (`%<id>`) for the colocated chat hook, which can't import module scope.
window.DoitRefTransformForSave = (text) => transformForSave(text, resolveRefPath)

// Post-patch rehydrate pass over every %-ref EDIT BOX (O&C 4.7). Two holes the
// per-hook lifecycle can't cover:
//   * morphdom's INPUT/TEXTAREA special handlers reset the value PROPERTY to
//     the raw stored `%<id>` text whenever a patch visits the element, while
//     LiveView fires the hook's updated() only when the server CONTENT changed
//     (the isEqualNode gate compares attributes/child text, never the
//     property) — so an unrelated patch silently swaps a rehydrated `%label`
//     back to the raw token with no callback to fix it.
//   * a re-number changes labels with NO patch to the field at all — the box
//     holds a stale `%label` containing no token, so a value-based rehydrate
//     has nothing left to re-resolve.
// Re-derive each box from el.defaultValue — the value attribute / child text
// morphdom KEEPS synced to the server's stored raw text — so every patch
// settles with fresh labels, pre-paint. Never touches the focused box, and
// never a box holding uncommitted user edits (a value matching neither the raw
// stored text nor the box's last derived display, el.doitRefShown).
function rehydrateRefFields() {
  document.querySelectorAll('[phx-hook="RefField"]').forEach((el) => {
    if (el === document.activeElement) return
    const raw = el.defaultValue
    if (typeof raw !== "string" || !/%<\d+>/.test(raw)) return
    if (el.value !== raw && el.value !== el.doitRefShown) return
    const next = rehydrate(raw, refLabelOf)
    if (el.value !== next) el.value = next
    el.doitRefShown = next
  })
}

// The "Linked <label> — <title>" notification when a save resolves a NEW/changed
// `%`-ref set is OWNED BY THE SERVER (WL3 item 3.5): the save handlers diff the
// ref set and put_flash it through the app's canonical flash/toast, so there is
// ONE toast system, not a client-side parallel. The client only transforms
// %label → %<id> on save (below); it no longer detects or renders the toast.

// Expand any collapsed ancestors of a task so it can be scrolled into view —
// derived from the DOM (walk up through the enclosing children <ul>s) and applied
// exactly like the deep-link / keyboard incantation (localStorage + collapsed-peek
// + aria-expanded), so the expand survives the post-load collapse-guard pass.
function expandRefAncestors(id) {
  let li = document.getElementById("task-" + id)
  while (li) {
    const ul = li.closest('ul[id^="children-"]')
    if (!ul) break
    const aid = ul.id.slice("children-".length)
    const btn = document.getElementById("collapse-" + aid)
    const init = ul.dataset.initiativeId || (btn && btn.dataset.initiativeId)
    if (init) localStorage.setItem(`phx:collapse:${init}:${aid}`, "0")
    ul.classList.remove("collapsed-peek")
    if (btn) btn.setAttribute("aria-expanded", "true")
    li = document.getElementById("task-" + aid)
  }
}

// Click a %-reference: select + scroll to the referenced task, expanding any
// collapsed ancestors first. The row-click selection handler already ignores
// clicks on <a>, so this never double-fires with row selection; dead refs are a
// <span> (not matched) and stay inert row text. Mirrors the .TaskKeys select +
// scroll primitive (DoitSelection.set + DoitPush("select_task")).
document.addEventListener("click", (e) => {
  const ref = e.target.closest("a.doit-ref[data-task-id]")
  if (!ref) return
  e.preventDefault()
  const id = ref.dataset.taskId
  if (!id || !document.getElementById("task-" + id)) return
  expandRefAncestors(id)
  // Defer a frame so just-expanded rows are laid out before scrollIntoView.
  requestAnimationFrame(() => {
    if (!document.getElementById("task-" + id)) return
    if (window.DoitSelection) window.DoitSelection.set(id, {scroll: true})
    if (window.DoitPush) window.DoitPush("select_task", {id})
  })
})

// ---------------------------------------------------------------------------
// %-reference "Link task" picker (Worklist 3 item 3.2) — CLIENT-ONLY.
//
// A small button next to each of the three eligible ref-input fields (add-task
// title, details title, details description) opens a popover: a search box + a
// scrollable list of THIS Initiative's tasks, built live from the tree DOM so it
// opens instantly with NO round trip (the picker is an optional aid — typing
// `%label` directly already works). Choosing a task inserts `%<label>` at the
// caret of the last-focused eligible field. The picker only inserts TEXT — the
// field's existing RefField save-transform anchors `%label` -> `%<id>` on blur
// (add-task on submit), so nothing here resolves or stores.
//
// Numbering-off choice: labels come from each row's [data-copy-index], which is
// present ONLY when Initiative numbering is on. With no labels the picker can't
// produce a `%label`, so the popover still OPENS (so a click is acknowledged,
// §6) but shows a "turn on Initiative numbering" hint instead of a task list —
// the button is never a dead no-op.

// The three fields that accept a %-ref. Stable selectors, so `.matches()` holds
// wherever the add-task form teleports in the tree.
const REF_PICKER_FIELDS =
  '#add-task-form input[name="title"], #task-field-title, #task-field-description, ' +
  "#initiative-subtitle, #initiative_description"
function refEligibleField(el) {
  return el && el.matches && el.matches(REF_PICKER_FIELDS) ? el : null
}

// The eligible field (+ caret) that last held focus — the insert target. Kept
// fresh on focus and on any selection change within an eligible field, so the
// caret survives the field blurring to the picker. `chooseRef` inserts into
// THIS field (spec 3.2.1); a picker button whose field was never focused falls
// back to the field it's anchored to (its own data-ref-picker selector).
let refPickerTarget = null // { el, caret }
function recordRefTarget(el) {
  const field = refEligibleField(el)
  if (!field) return
  const caret =
    typeof field.selectionStart === "number" ? field.selectionStart : field.value.length
  refPickerTarget = {el: field, caret}
}
document.addEventListener("focusin", (e) => recordRefTarget(e.target))
;["keyup", "pointerup", "input", "select"].forEach((type) =>
  document.addEventListener(
    type,
    (e) => { if (refEligibleField(e.target)) recordRefTarget(e.target) },
    true
  )
)
// Snapshot the caret at the instant a picker button is pressed: on mousedown the
// field is still focused (blur happens in the default action AFTER this), so
// document.activeElement is the true target with a live selectionStart.
document.addEventListener(
  "mousedown",
  (e) => { if (e.target.closest("[data-ref-picker]")) recordRefTarget(document.activeElement) },
  true
)

let refPopover = null // singleton popover (lazily built, hosted on <body>)
let refPickerTrigger = null // the button that opened it (click-outside + toggle)
let refPickerItems = [] // [{label, title, hay}] full task list for the open picker
let refActiveIndex = -1 // highlighted row in the filtered list

function ensureRefPopover() {
  if (refPopover) return refPopover
  const pop = document.createElement("div")
  pop.id = "ref-picker-popover"
  pop.hidden = true
  pop.setAttribute("role", "dialog")
  pop.setAttribute("aria-label", "Link a task")
  pop.className =
    "fixed z-50 w-72 max-w-[calc(100vw-1rem)] rounded-lg border border-zinc-300 dark:border-zinc-700 bg-white dark:bg-zinc-900 shadow-xl p-2"
  const search = document.createElement("input")
  search.type = "text"
  search.setAttribute("data-ref-search", "")
  search.placeholder = "Search by number or title…"
  search.className = "w-full mb-2 input input-bordered input-sm"
  const list = document.createElement("ul")
  list.setAttribute("data-ref-list", "")
  list.className = "max-h-64 overflow-y-auto text-sm"
  pop.appendChild(search)
  pop.appendChild(list)
  // Body-hosted, so it lives OUTSIDE the LiveView root — morphdom never patches
  // it, and it survives tree re-renders while open.
  document.body.appendChild(pop)
  refPopover = pop
  search.addEventListener("input", () => renderRefList(search.value))
  search.addEventListener("keydown", onRefSearchKeydown)
  list.addEventListener("click", (e) => {
    const li = e.target.closest("[data-ref-label]")
    if (li) chooseRef(li.getAttribute("data-ref-label"))
  })
  return pop
}

// Build the task list live from the tree DOM: each row's [data-copy-index]
// (its clean dotted label) + [data-task-title]. Empty when numbering is off.
function collectRefTasks() {
  const items = []
  document.querySelectorAll("#task-tree [data-copy-index]").forEach((el) => {
    const li = el.closest("li[data-task-id]")
    if (!li) return
    const label = el.getAttribute("data-copy-index")
    if (!label) return
    const titleEl = li.querySelector(":scope > [data-task-row] [data-task-title]")
    const title = titleEl ? titleEl.textContent.trim() : ""
    items.push({label, title, hay: (label + " " + title).toLowerCase()})
  })
  return items
}

function refListEls() {
  return refPopover ? [...refPopover.querySelectorAll("[data-ref-label]")] : []
}

function renderRefList(query) {
  const list = refPopover.querySelector("[data-ref-list]")
  const q = (query || "").trim().toLowerCase()
  list.replaceChildren()
  refActiveIndex = -1
  const hint = (text) => {
    const li = document.createElement("li")
    li.className = "px-2 py-3 text-xs text-zinc-500 dark:text-zinc-400 italic"
    li.textContent = text
    list.appendChild(li)
  }
  if (refPickerItems.length === 0) {
    hint("Turn on Initiative numbering to link tasks by number.")
    return
  }
  const matches = q ? refPickerItems.filter((it) => it.hay.includes(q)) : refPickerItems
  if (matches.length === 0) {
    hint("No matching tasks.")
    return
  }
  matches.forEach((it) => {
    const li = document.createElement("li")
    li.setAttribute("data-ref-label", it.label)
    li.className =
      "flex items-baseline gap-2 px-2 py-1.5 rounded cursor-pointer hover:bg-emerald-50 dark:hover:bg-emerald-900/30 aria-selected:bg-emerald-100 dark:aria-selected:bg-emerald-900/50"
    const num = document.createElement("span")
    num.className =
      "flex-none font-mono text-xs font-semibold text-emerald-700 dark:text-emerald-400 tabular-nums"
    num.textContent = it.label
    const ttl = document.createElement("span")
    ttl.className = "truncate text-zinc-700 dark:text-zinc-200"
    ttl.textContent = it.title
    li.appendChild(num)
    li.appendChild(ttl)
    list.appendChild(li)
  })
  refActiveIndex = 0
  highlightRef()
}

function highlightRef() {
  refListEls().forEach((li, i) => {
    const active = i === refActiveIndex
    li.setAttribute("aria-selected", active ? "true" : "false")
    if (active) li.scrollIntoView({block: "nearest"})
  })
}

function moveRefActive(dir) {
  const els = refListEls()
  if (els.length === 0) return
  refActiveIndex = Math.max(0, Math.min(els.length - 1, refActiveIndex + dir))
  highlightRef()
}

function onRefSearchKeydown(e) {
  switch (e.key) {
    case "ArrowDown":
      e.preventDefault()
      moveRefActive(1)
      break
    case "ArrowUp":
      e.preventDefault()
      moveRefActive(-1)
      break
    case "Enter": {
      e.preventDefault()
      const li = refListEls()[refActiveIndex]
      if (li) chooseRef(li.getAttribute("data-ref-label"))
      break
    }
    case "Escape":
      e.preventDefault()
      closeRefPicker(true)
      break
  }
}

function positionRefPopover(trigger) {
  const r = trigger.getBoundingClientRect()
  const pw = refPopover.offsetWidth
  const ph = refPopover.offsetHeight
  let left = Math.min(r.left, window.innerWidth - pw - 8)
  if (left < 8) left = 8
  let top = r.bottom + 4
  if (top + ph > window.innerHeight - 8) {
    const above = r.top - 4 - ph
    if (above > 8) top = above
  }
  refPopover.style.left = left + "px"
  refPopover.style.top = top + "px"
}

function openRefPicker(trigger) {
  ensureRefPopover()
  refPickerTrigger = trigger
  // Target field: the last-focused eligible field (spec 3.2.1) when still on
  // page, else the field this button is anchored to, caret at end.
  const last = refPickerTarget
  if (!last || !last.el.isConnected || !refEligibleField(last.el)) {
    const sel = trigger.getAttribute("data-ref-picker")
    const el = sel && document.querySelector(sel)
    refPickerTarget = el ? {el, caret: el.value.length} : null
  }
  refPickerItems = collectRefTasks()
  const search = refPopover.querySelector("[data-ref-search]")
  search.value = ""
  renderRefList("")
  refPopover.hidden = false
  positionRefPopover(trigger)
  search.focus()
}

function closeRefPicker(returnFocus) {
  if (!refPopover || refPopover.hidden) return
  refPopover.hidden = true
  const t = refPickerTarget
  refPickerTrigger = null
  if (returnFocus && t && t.el.isConnected) {
    t.el.focus()
    const pos = Math.min(t.caret == null ? t.el.value.length : t.caret, t.el.value.length)
    try { t.el.setSelectionRange(pos, pos) } catch (_e) {}
  }
}

// Insert `%<label>` at the tracked caret of the target field, restore focus,
// place the caret AFTER the insert, and fire `input` so the row echo + any
// validation update. RefField's blur transform (or the add-task submit) later
// anchors the `%label` to its `%<id>` token — we never store here.
function chooseRef(label) {
  refPopover.hidden = true
  refPickerTrigger = null
  const t = refPickerTarget
  if (!t || !t.el.isConnected) return
  const el = t.el
  const v = el.value
  const pos = Math.min(Math.max(t.caret == null ? v.length : t.caret, 0), v.length)
  const insert = "%" + label
  el.value = v.slice(0, pos) + insert + v.slice(pos)
  el.focus()
  const after = pos + insert.length
  try { el.setSelectionRange(after, after) } catch (_e) {}
  el.dispatchEvent(new Event("input", {bubbles: true}))
  // Advance the tracked caret so a follow-up pick lands after this insert.
  refPickerTarget = {el, caret: after}
}

document.addEventListener("click", (e) => {
  const trigger = e.target.closest("[data-ref-picker]")
  if (trigger) {
    e.preventDefault()
    if (refPopover && !refPopover.hidden && refPickerTrigger === trigger) {
      closeRefPicker(true) // second click on the same button toggles it closed
    } else {
      openRefPicker(trigger)
    }
    return
  }
  // Click-outside: dismiss (no focus return — the user is going elsewhere).
  if (refPopover && !refPopover.hidden && !e.target.closest("#ref-picker-popover")) {
    closeRefPicker(false)
  }
})

// Escape closes + returns focus to the field, ahead of the other Escape owners.
document.addEventListener(
  "keydown",
  (e) => {
    if (e.key === "Escape" && refPopover && !refPopover.hidden) {
      e.preventDefault()
      e.stopPropagation()
      closeRefPicker(true)
    }
  },
  true
)

// Keep the popover glued to its trigger through outer scroll/resize (ignore the
// popover's own list scroll).
window.addEventListener("resize", () => {
  if (refPopover && !refPopover.hidden && refPickerTrigger) positionRefPopover(refPickerTrigger)
})
document.addEventListener(
  "scroll",
  (e) => {
    if (!refPopover || refPopover.hidden || !refPickerTrigger) return
    if (e.target && e.target.closest && e.target.closest("#ref-picker-popover")) return
    positionRefPopover(refPickerTrigger)
  },
  true
)

// Optimistically pull a user's row from the pane's co-assignee list — used when
// they're promoted to PRIMARY (a person can't be both). The list is the same
// hook-owned (phx-update="ignore") <ul> the CoAssignees hook drives, so we touch
// it the same way: remove the row, restore the "None yet." empty placeholder if
// it was the last, and re-derive the move up/down disabled-state. No-op when the
// user isn't a co-assignee.
function dropCoAssigneeRow(userId) {
  const ul = document.querySelector('#co-assignees [id^="co-list-"]')
  if (!ul) return
  const row = ul.querySelector(`[data-co-row][data-user-id="${userId}"]`)
  if (!row) return
  row.remove()
  if (!ul.querySelector("[data-co-row]")) {
    const li = document.createElement("li")
    li.setAttribute("data-co-empty", "")
    li.className = "text-xs text-zinc-400 dark:text-zinc-500 italic"
    li.textContent = "None yet."
    ul.appendChild(li)
  }
  const rows = [...ul.querySelectorAll("[data-co-row]")]
  rows.forEach((li, i) => {
    const up = li.querySelector("[data-dir='up']")
    const down = li.querySelector("[data-dir='down']")
    if (up) up.disabled = i === 0
    if (down) down.disabled = i === rows.length - 1
  })
}

// Client-instant delete confirms (.03.07.15 task, .03.07.18 initiative;
// UX_GUARDRAILS 6.5): both dialogs' content is already client-known, so they
// open at the click — no round trip before the user can decide. The task
// dialog holds a sticky maybe-write hue on the doomed subtree; Cancel clears
// it, Delete optimistically removes the row (pinking the surviving ancestors)
// and pushes the actual delete. The initiative dialog needs no fill or hue —
// Proceed pushes delete_initiative and the server navigates away.
const DELETE_MODAL_IDS = ["delete-confirm", "delete-initiative-confirm"]
const openDeleteModal = () =>
  DELETE_MODAL_IDS.map((id) => document.getElementById(id)).find((m) => m && !m.hidden)

document.addEventListener("click", (e) => {
  if (e.target.closest("#delete-task-btn")) {
    const li = selectedLi()
    const modal = document.getElementById("delete-confirm")
    if (!li || !modal) return
    modal.dataset.taskId = li.dataset.taskId
    const title = li.querySelector(":scope > [data-task-row] [data-task-title]")
    modal.querySelector("[data-delete-title]").textContent = title ? title.textContent.trim() : ""
    markSaving(savingSubtree(li), {sticky: true})
    modal.hidden = false
    const cancel = modal.querySelector("[data-delete-cancel]")
    if (cancel) cancel.focus()
    return
  }
  if (e.target.closest("#delete-initiative-btn")) {
    const modal = document.getElementById("delete-initiative-confirm")
    if (!modal) return
    modal.hidden = false
    const cancel = modal.querySelector("[data-delete-cancel]")
    if (cancel) cancel.focus()
    return
  }
  const modal = openDeleteModal()
  if (!modal) return
  // Mid-commit ("Deleting…", initiative trash) — backdrop / Cancel can't dismiss
  // it while the server moves it to Trash + navigates (mirrors leave-confirm).
  if (modal.dataset.deleting === "true") return
  // Backdrop click or Cancel — close without consequence.
  if (e.target === modal || e.target.closest("[data-delete-cancel]")) {
    modal.hidden = true
    clearSavingHue()
    return
  }
  if (e.target.closest("[data-delete-proceed]")) {
    if (modal.id === "delete-confirm") {
      // Task delete: optimistic — remove the row, pink the surviving ancestors,
      // then push. The dialog closes at once (the result is client-known).
      modal.hidden = true
      clearSavingHue()
      const li = document.getElementById("task-" + modal.dataset.taskId)
      if (li) { markSaving(savingAncestors(li)); li.remove() }
      if (window.DoitPush) window.DoitPush("delete_task", {id: modal.dataset.taskId})
      return
    }
    // Initiative delete (move-to-Trash): server-gated — the server trashes then
    // push_navigates away. Don't hide; latch Proceed ("Deleting…", disabled,
    // pulse) so the wait isn't dead air (UX_GUARDRAILS §6.7), exactly like the
    // leave-confirm / archive-confirm Proceeds. The navigation replaces this
    // modal on success; a refusal / dropped reply restores it (8s safety).
    const proceed = modal.querySelector("[data-delete-proceed]")
    const cancel = modal.querySelector("[data-delete-cancel]")
    modal.dataset.deleting = "true"
    if (cancel) cancel.disabled = true
    // Route Proceed through the shared latch so it gets the same label swap +
    // spinner glyph every server-gated button shows; compose the modal-hold
    // (don't dismiss; lock Cancel) around its idempotent restore.
    const restoreLatch = latchButton(proceed, "Deleting…")
    const restore = () => {
      restoreLatch()
      delete modal.dataset.deleting
      if (cancel) cancel.disabled = false
    }
    const t = setTimeout(restore, 8000) // dropped reply → never hang
    if (window.DoitPush) {
      window.DoitPush("delete_initiative", {}, (reply) => {
        clearTimeout(t)
        // ok commit ends in push_navigate (this page is replaced — stay latched);
        // a refusal / dropped reply restores so they can retry.
        if (reply && reply.ok === false) restore()
      })
    } else {
      clearTimeout(t)
      restore()
    }
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = openDeleteModal()
  // A mid-commit initiative trash holds; Escape can't dismiss it.
  if (modal && modal.dataset.deleting !== "true") {
    modal.hidden = true
    clearSavingHue()
  }
})

// Leave-Initiative confirm — opens client-side so the dialog never waits on the
// server (UX_GUARDRAILS 6.5, like the delete confirms). Proceed pushes
// leave_initiative (the only server touch); Cancel / backdrop / Esc just close.
document.addEventListener("click", (e) => {
  const modal = document.getElementById("leave-confirm")
  if (!modal) return
  if (e.target.closest("[data-leave-initiative]")) {
    e.preventDefault()
    modal.hidden = false
    const cancel = modal.querySelector("[data-leave-cancel]")
    if (cancel) cancel.focus()
    return
  }
  if (modal.hidden) return
  // Mid-commit ("Leaving…") — backdrop / Cancel can't dismiss it.
  if (modal.dataset.leaving === "true") return
  if (e.target === modal || e.target.closest("[data-leave-cancel]")) {
    modal.hidden = true
    return
  }
  if (e.target.closest("[data-leave-proceed]")) {
    // Don't dismiss — leaving is server-confirmed (the members_changed
    // broadcast navigates you away on commit). Hold a "Leaving…" state so the
    // wait isn't dead air on a live-looking initiative; the page navigation
    // replaces this modal on success. Restore on a refusal / dropped reply.
    const proceed = modal.querySelector("[data-leave-proceed]")
    const cancel = modal.querySelector("[data-leave-cancel]")
    modal.dataset.leaving = "true"
    if (cancel) cancel.disabled = true
    // Shared latch (label swap + spinner glyph) + the modal-hold around it.
    const restoreLatch = latchButton(proceed, "Leaving…")
    const restore = () => {
      restoreLatch()
      delete modal.dataset.leaving
      if (cancel) cancel.disabled = false
    }
    const t = setTimeout(restore, 8000) // dropped reply → never hang
    if (window.DoitPush) {
      window.DoitPush("leave_initiative", {}, (reply) => {
        clearTimeout(t)
        // ok:true → committed; the eject navigation replaces this page, so stay
        // "Leaving…". ok:false / no reply → restore so they can retry.
        if (!reply || reply.ok === false) restore()
      })
    } else {
      clearTimeout(t)
      restore()
    }
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = document.getElementById("leave-confirm")
  if (modal && !modal.hidden && modal.dataset.leaving !== "true") modal.hidden = true
})

// Comment inline editor + edit-history popup — open/close is CLIENT-OWNED (WL3
// 3.3, §6.5). Both the display block and the author's form render statically;
// these toggles flip DoitState and re-run the row's keep applier at once, so the
// reveal is instant with zero round trip. The comment id comes from the row's
// `id="comment-<id>"`. SAVE stays server-owned (the form's phx-submit); the
// server closes the editor by pushing "comment-saved" (TaskKeys hook) — these
// listeners never fake a save.
function commentIdOf(el) {
  const li = el.closest("li[id^='comment-']")
  return li ? li.id.slice("comment-".length) : null
}
document.addEventListener("click", (e) => {
  const editOpen = e.target.closest("[data-comment-edit-open]")
  if (editOpen) {
    const id = commentIdOf(editOpen)
    if (!id) return
    DoitState.commentEditId = id
    const li = document.getElementById(`comment-${id}`)
    if (li && window.DoitApplyKeep) window.DoitApplyKeep(li)
    // Seed + focus the textarea so the editor opens on the current body with the
    // caret at the end — no stale value, ready to type.
    const form = li && li.querySelector("[data-comment-edit-form]")
    const ta = form && form.querySelector("textarea")
    if (ta) {
      ta.focus()
      ta.setSelectionRange(ta.value.length, ta.value.length)
    }
    return
  }
  const editCancel = e.target.closest("[data-comment-edit-cancel]")
  if (editCancel) {
    const id = commentIdOf(editCancel)
    DoitState.commentEditId = null
    const li = id && document.getElementById(`comment-${id}`)
    if (li && window.DoitApplyKeep) window.DoitApplyKeep(li)
    return
  }
  const versOpen = e.target.closest("[data-comment-versions-open]")
  if (versOpen) {
    const id = commentIdOf(versOpen)
    if (!id) return
    DoitState.commentVersionsId = id
    const popup = document.getElementById(`comment-versions-${id}`)
    if (popup && window.DoitApplyKeep) window.DoitApplyKeep(popup)
    return
  }
  const versCancel = e.target.closest("[data-comment-versions-cancel]")
  if (versCancel) {
    const id = commentIdOf(versCancel)
    DoitState.commentVersionsId = null
    const popup = id && document.getElementById(`comment-versions-${id}`)
    if (popup && window.DoitApplyKeep) window.DoitApplyKeep(popup)
    return
  }
})
// True when a full-screen overlay modal (leave / handoff / archive / delete /
// transfer — all `fixed inset-0`, none `hidden`) is currently open. The comment
// editor + history popup live in the always-rendered Details pane BEHIND such an
// overlay, so when one is up Escape belongs to it — not the editor underneath.
// Without this, one Escape would dismiss the overlay AND silently discard the
// editor's unsaved text.
function overlayModalOpen() {
  return Array.from(document.querySelectorAll(".fixed.inset-0")).some(
    (el) => !el.hidden && el.offsetParent !== null
  )
}
// Escape closes an open comment editor / history popup (closest one first), the
// same client-owned dismissal the Cancel buttons do — unless an overlay modal is
// up, which owns the Escape.
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape" || overlayModalOpen()) return
  if (DoitState.commentEditId != null) {
    const li = document.getElementById(`comment-${DoitState.commentEditId}`)
    DoitState.commentEditId = null
    if (li && window.DoitApplyKeep) window.DoitApplyKeep(li)
    return
  }
  if (DoitState.commentVersionsId != null) {
    const popup = document.getElementById(`comment-versions-${DoitState.commentVersionsId}`)
    DoitState.commentVersionsId = null
    if (popup && window.DoitApplyKeep) window.DoitApplyKeep(popup)
  }
})

// Hand-off-cancel modal close — the dismissal is CLIENT-OWNED (WL3 3.3, §6.5),
// mirroring the leave-confirm convention. The OPEN still round-trips (the body
// needs the server's assignment count), so the modal renders from @pending_handoff
// and confirm_handoff (the real write) is untouched. Cancel / backdrop / Escape
// hide the modal INSTANTLY, then push cancel_handoff reconciliatorily so the
// server clears its pending_handoff assign (the next patch re-hides it idempotently).
document.addEventListener("click", (e) => {
  const modal = document.getElementById("handoff-confirm")
  if (!modal || modal.hidden) return
  if (e.target === modal || e.target.closest("[data-handoff-cancel]")) {
    modal.hidden = true
    if (window.DoitPush) window.DoitPush("cancel_handoff", {})
  }
})
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = document.getElementById("handoff-confirm")
  if (!modal || modal.hidden) return
  modal.hidden = true
  if (window.DoitPush) window.DoitPush("cancel_handoff", {})
})

// Archive confirm — the gate is decided WITHOUT a round trip (UX_GUARDRAILS
// 6.5): the owner case predicts from the DOM (any incomplete task in the tree);
// the member case defers to the server backstop, which replies needs_confirm
// only when there's actually unfinished work. Proceed commits with confirmed.
//
// In-flight signifier (WL3 item 3.7, §6.7): the originating control latches —
// disabled + "Archiving…" + pulse — so the wait on the push_navigate isn't
// dead air. A non-committing reply (needs_confirm probe) or a refusal / dropped
// reply restores it; an ok commit stays latched because the navigation
// replaces the whole page. Mirrors the leave_initiative latch above.
function latchArchiveBtn(ctl) {
  // Shares the one latch path (label swap + spinner glyph + pulse/dim), so the
  // archive button (icon + " Archive") and the modal Proceed (text-only) both
  // acknowledge identically to every other server-gated button.
  return latchButton(ctl, "Archiving…")
}

function pushArchive(confirmed, ctl, onRestore) {
  if (!window.DoitPush) return
  // Latch the originating control now — the client can't know in advance
  // whether the server will commit or reply needs_confirm (the member case
  // only the server decides), so we latch optimistically and release on a
  // non-commit reply. A commit ends in push_navigate (stays latched); a
  // needs_confirm probe / refusal / dropped reply restores it.
  const latch = latchArchiveBtn(ctl)
  const restore = () => { latch(); if (onRestore) onRestore() }
  const t = setTimeout(restore, 8000) // dropped reply → never hang
  window.DoitPush("archive_initiative", confirmed ? {confirmed: true} : {}, (reply) => {
    clearTimeout(t)
    if (reply && reply.needs_confirm) {
      restore() // the probe came back asking — release and open the modal
      const m = document.getElementById("archive-confirm")
      if (m) m.hidden = false
    } else if (!reply || reply.ok === false) {
      restore() // refusal / dropped reply → let them retry
    }
    // ok:true → stay latched; the push_navigate replaces this page.
  })
}

document.addEventListener("click", (e) => {
  const modal = document.getElementById("archive-confirm")
  const btn = e.target.closest("[data-archive-btn]")
  if (btn) {
    e.preventDefault()
    const owner = btn.dataset.amOwner === "true"
    // Incomplete rows carry NO data-done attribute: it renders as a boolean
    // attr (data-done={status == "done"}), which HEEx omits when false. So
    // "any incomplete task" = any row WITHOUT data-done (:not([data-done])).
    const needsConfirm =
      owner && !!document.querySelector("#task-tree [data-task-row]:not([data-done])")
    if (needsConfirm && modal) {
      modal.hidden = false
    } else {
      // Committing straight away — latch the archive button (member case may
      // still probe needs_confirm, which releases it and opens the modal).
      pushArchive(false, btn)
    }
    return
  }
  if (!modal || modal.hidden) return
  // Mid-commit ("Archiving…") — backdrop / Cancel can't dismiss it.
  if (modal.dataset.archiving === "true") return
  if (e.target === modal || e.target.closest("[data-archive-cancel]")) {
    modal.hidden = true
    return
  }
  const proceed = e.target.closest("[data-archive-proceed]")
  if (proceed) {
    // Don't hide — Proceed commits; latch it through the navigate (the page
    // replacement tears down the modal). A refusal / dropped reply restores it.
    modal.dataset.archiving = "true"
    pushArchive(true, proceed, () => { delete modal.dataset.archiving })
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const m = document.getElementById("archive-confirm")
  if (m && !m.hidden && m.dataset.archiving !== "true") m.hidden = true
})

// ---------------------------------------------------------------------------
// Up-front in-flight latches for server-gated controls (WL4.3, §6.7).
//
// Several not-immediate actions today acknowledge ONLY through LiveView-applied
// phx-disable-with / phx-click-loading — neither of which is attached until the
// view is live, so they signal NOTHING in the pre-connect dead window (and the
// show-page Hide button signalled nothing even when live). These delegated
// listeners, registered at module load, set the in-flight cue at the gesture
// itself — connect-independent, exactly like the leave_initiative / archive
// latches above. They are in-flight signifiers ONLY, never success: the action
// rides its own native phx-click / phx-submit, captured + replayed across the
// dead window by the §6.8 interceptor (4.2) and reconciled by the server's
// render; the 8s safety timer only restores a control if no patch / navigation
// already has (MUST NOT LIE — never an unearned "done"). The phx-disable-with
// that used to label these is DROPPED wherever a latch replaces it, so the
// label never swaps twice.

// A small inline "working" spinner glyph — a hero-arrow-path icon span that
// spins (motion-safe). Built in JS (not HEEx) so latchButton can append it to a
// labelled button AT the gesture; the hero-arrow-path mask CSS + the
// size/motion-safe utilities are already in the bundle (the reveal slot + the
// connecting badge render the same icon), and @source "../js" keeps them
// generated. Shape + motion, not color, so the cue reads for colorblind users;
// motion-safe so reduced-motion users get a static (still-legible) glyph.
function busyGlyph() {
  const s = document.createElement("span")
  s.className = "hero-arrow-path doit-busy-glyph ml-1 size-3.5 flex-none animate-spin"
  s.setAttribute("aria-hidden", "true")
  return s
}

// Latch one server-gated control to its in-flight state — the connect-independent
// stand-in for phx-disable-with (§6.7). ONE path covers both button shapes:
//   • text/labelled button → swap the trailing label ("Hide" → "Hiding…"), pulse +
//     dim, and append a spinning glyph beside the label.
//   • icon-only button (no text node — e.g. a close "X") → swap its hero-* icon to
//     a spinning hero-arrow-path IN PLACE, same box/position (the operator's exact
//     ask: the clicked X becomes a spinner), restored on settle.
// Both announce via aria-busy AT ONCE and disable on the next microtask. The defer
// matters: LiveView's closestPhxBinding skips a `disabled` control and a disabled
// submitter drops from the serialized form, so a synchronous disable would
// suppress the very LIVE phx-click / phx-submit we're acknowledging — the
// microtask lets that handler run first, then locks the control. An ~8s safety
// timer self-restores if nothing supersedes it (dropped reply → never stuck); a
// server morphdom re-render of the control restores it earlier where one happens.
// Returns the restore fn; idempotent. Generalizes latchArchiveBtn so every
// up-front latch site shares one path. Leading whitespace of the original label
// is preserved, so an icon + " Hide" becomes an icon + " Hiding…".
function latchButton(btn, label) {
  if (!btn || btn.dataset.latched === "true") return () => {}
  const textNode = [...btn.childNodes].reverse().find((n) => n.nodeType === 3 && n.textContent.trim())
  btn.dataset.latched = "true"
  btn.setAttribute("aria-busy", "true")
  let undoShape
  if (textNode) {
    // Text shape: label swap + pulse/dim + a trailing spinner glyph.
    const prior = textNode.textContent
    const lead = (prior.match(/^\s*/) || [""])[0]
    if (label) textNode.textContent = lead + label
    btn.classList.add("animate-pulse", "opacity-60")
    const glyph = busyGlyph()
    btn.appendChild(glyph)
    undoShape = () => {
      btn.classList.remove("animate-pulse", "opacity-60")
      if (prior != null) textNode.textContent = prior
      glyph.remove()
    }
  } else {
    // Icon-only shape: swap the hero-* icon span to a spinning hero-arrow-path,
    // same box; restore the original icon class on settle.
    const icon = btn.querySelector('[class*="hero-"]')
    const priorClass = icon ? icon.className : null
    if (icon) {
      const swapped = priorClass.replace(/hero-[\w-]+/, "hero-arrow-path")
      icon.className = /animate-spin/.test(swapped) ? swapped : swapped + " animate-spin"
    }
    undoShape = () => { if (icon && priorClass != null) icon.className = priorClass }
  }
  // Lock out further clicks via pointer-events, NOT `disabled`: disabling the
  // button mid-click makes LiveView's bubble-phase phx-click handler skip the
  // disabled target (closestPhxBinding ignores `el.disabled`), dropping the very
  // real click we're acknowledging. pointer-events:none blocks subsequent clicks
  // without that side effect. Still deferred a microtask so it can't affect the
  // current click's hit-testing.
  queueMicrotask(() => { btn.style.pointerEvents = "none" })
  let restored = false
  const restore = () => {
    if (restored) return
    restored = true
    clearTimeout(timer)
    delete btn.dataset.latched
    btn.style.pointerEvents = ""
    btn.removeAttribute("aria-busy")
    undoShape()
  }
  const timer = setTimeout(restore, 8000)
  return restore
}

// In-place busy cue for controls that can't be re-labelled or icon-swapped —
// a <select> or checkbox (§6.7). Set `.doit-busy` + aria-busy on the control AT
// the gesture; the CSS reveals a spinner in the adjacent fixed-width
// `.doit-busy-slot` (a generalization of the reveal toggle's slot — visibility
// only, so the control never shifts). Cleared when the action settles: the
// server's morphdom re-render strips the JS-added class/attr where the control
// re-renders, the returned fn clears it where there's a reply, and an ~8s safety
// timer self-heals a dropped reply (phx-update="ignore" controls never re-render).
function setControlBusy(el, timeout = 8000) {
  if (!el) return () => {}
  el.classList.add("doit-busy")
  el.setAttribute("aria-busy", "true")
  let done = false
  const clear = () => {
    if (done) return
    done = true
    clearTimeout(t)
    el.classList.remove("doit-busy")
    el.removeAttribute("aria-busy")
  }
  const t = setTimeout(clear, timeout)
  return clear
}

// In-place "working" spinner for navigation controls (§6.7). Opening an
// Initiative (the center workspace card, a left-rail entry, an Assigned-to-Me
// row) and the "Close Initiative" control each do a REAL server round trip
// (push_patch / navigate → handle_params load), but nothing on the CLICKED
// control acknowledged it — the destination view just swapped in a beat later.
// Mark the clicked control busy AT the gesture: append the shared spinning glyph
// (busyGlyph — hero-arrow-path, motion-safe, shape+motion not color so it reads
// in both themes / for colorblind users) and raise aria-busy. Clearing:
//   • a control the nav REMOVES (a card swapped for the detail view, a
//     cross-page row) loses its spinner with the element — nothing to clear;
//   • a control that PERSISTS (the left-rail entry stays in the rail) is cleared
//     when the nav settles — phx:page-loading-stop runs clearAllNavBusy below
//     (and morphdom drops the non-template glyph on the landing patch anyway).
// An ~8s per-control safety clears a stuck spinner if the stop signal never
// lands. Connect-independent: pure DOM at the gesture, no live socket required.
const navBusyEntries = new Set()

function markNavBusy(el) {
  if (!el || el.dataset.navBusy === "true") return
  el.dataset.navBusy = "true"
  el.setAttribute("aria-busy", "true")
  const glyph = busyGlyph()
  el.appendChild(glyph)
  const entry = { el, glyph, timer: null }
  entry.timer = setTimeout(() => clearNavBusy(entry), 8000)
  navBusyEntries.add(entry)
}

function clearNavBusy(entry) {
  if (!navBusyEntries.has(entry)) return
  navBusyEntries.delete(entry)
  clearTimeout(entry.timer)
  if (entry.el) {
    entry.el.removeAttribute("aria-busy")
    delete entry.el.dataset.navBusy
  }
  if (entry.glyph) entry.glyph.remove()
}

function clearAllNavBusy() {
  for (const entry of [...navBusyEntries]) clearNavBusy(entry)
}

// Spin the clicked nav control. Skip modified / non-primary clicks (a
// cmd/ctrl/shift/middle click opens a new tab — LiveView doesn't SPA-navigate
// those, so there'd be no nav to clear the spinner). NOT guarded on
// defaultPrevented: LiveView preventDefaults a <.link> click precisely BECAUSE
// it's handling the in-page nav, which is exactly when we want the cue.
document.addEventListener("click", (e) => {
  if (e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return
  const ctl = e.target.closest("[data-nav-spinner]")
  if (ctl) markNavBusy(ctl)
})

// Click-fired latches (type=button controls): the show-page Hide, plus the
// Archived / Trash row actions (unhide, unarchive-restore, restore-from-trash).
// Each carries data-latch="<in-flight label>". No preventDefault — the native
// phx-click still runs (live) or is captured by 4.2 (dead window). Submit
// buttons are left to the submit listener below.
document.addEventListener("click", (e) => {
  const btn = e.target.closest("button[data-latch]")
  if (!btn || btn.type === "submit") return
  latchButton(btn, btn.getAttribute("data-latch"))
})

// Submit-fired latches: the connect-independent stand-in for phx-disable-with on
// server-gated form submits (Create initiative, Add member, Save edited comment,
// the account Profile / Username / Password / Preferences saves). The submit
// button carries data-latch="<label>"; latch it as the form submits. NEVER
// preventDefault / stopPropagation here — LiveView's own phx-submit must run
// (live) and 4.2's capture-phase listener owns the dead window.
document.addEventListener("submit", (e) => {
  const form = e.target
  if (!form || !form.querySelector) return
  const btn =
    (e.submitter && e.submitter.matches && e.submitter.matches("[data-latch]") && e.submitter) ||
    form.querySelector("[type='submit'][data-latch]")
  if (btn) latchButton(btn, btn.getAttribute("data-latch"))
})

// ---------------------------------------------------------------------------
// Optimistic echoes for server-gated comment writes (WL3 item 3.6, §6.7).
// add_comment / save_comment are phx-submit (server-driven), but the result
// shows in the same pane — so we acknowledge instantly at submit and let the
// reply (or the reconciling refresh_selected render) settle it. MUST NOT LIE:
// a rejected add pulls its bubble; a rejected edit reverts to the saved text.
// ---------------------------------------------------------------------------

// ADD-COMMENT: intercept the submit, insert a dimmed pending <li>, and push via
// DoitPush so we get the reply callback (the same contract used everywhere
// else). On ok the refresh_selected render carries the real comment and we pull
// the pending one; on !ok the bubble must not stand (MUST NOT LIE). Registered
// in capture phase (like #add-task-form) and stopImmediatePropagation() so
// LiveView's bubble-phase phx-submit never double-posts.
document.addEventListener(
  "submit",
  (e) => {
    const form = e.target.closest("[data-add-comment-form]")
    if (!form) return
    const input = form.querySelector("[name='comment[body]']")
    const raw = input ? input.value.trim() : ""
    if (!window.DoitPush) return // no push channel → let the native phx-submit run
    e.preventDefault()
    e.stopImmediatePropagation() // stop LiveView's own phx-submit push
    if (!raw) return // empty → nothing to send (the server would just reject it)
    // Resolve any `%label` refs to their stored `%<id>` token BEFORE the push, so
    // the server persists the id-anchored form (Wave 3 — no server change, no
    // edge; the comment body is just a string the client transforms).
    const body = transformForSave(raw, resolveRefPath)
    // The echo bubble lands in THIS form's own thread — the task pane and the
    // Initiative-details pane (item 6.4) each wrap their list + form in a
    // [data-comments-block], so scope the lookup to the submitting form's block.
    const list = (form.closest("[data-comments-block]") || document).querySelector(
      "[data-comment-list]"
    )
    const echoId = "c" + Date.now() + "-" + Math.random().toString(36).slice(2, 8)
    if (list) {
      const li = buildPendingComment(echoId, body, form.dataset)
      // Top of the list: the panes render newest-first (O&C 6.6), so the echo
      // lands exactly where the server's real row will. Reconcile is untouched
      // — removePendingComment pulls by echo_id, position-independent.
      list.prepend(li)
      renderAllRefs(li) // show the token -> link in the optimistic bubble at once
    }
    if (input) input.value = ""
    // The Initiative-details form names its thread (task_id = the root task,
    // item 6.4); the task pane's form carries none and means the selection.
    const payload = {comment: {body}, echo_id: echoId}
    if (form.dataset.taskId) payload.task_id = form.dataset.taskId
    window.DoitPush(
      "add_comment",
      payload,
      (reply) => {
        // ok → the refresh carries the real li; pull the pending stand-in.
        // !ok → the comment was refused (permission / empty); pull it too.
        removePendingComment((reply && reply.echo_id) || echoId)
      }
    )
    // The "Linked …" flash (if this adds a ref) is put by add_comment on the
    // server — no client toast.
  },
  true // capture phase: run before LiveView's bubble-phase phx-submit handler
)

// ANY form holding RefFields (the task pane + initiative editor): a submit
// (Enter) serializes every field's DISPLAYED value — the rehydrated `%label`,
// not the stored `%<id>` token — so an unintercepted submit would re-save the
// labels literally, destroying the stored references (O&C 4.7/4.9). In CAPTURE
// phase (before LiveView's bubble-phase submit serialization, same ordering as
// the intercepts around this): anchor every ref field in the submitting form
// back to token form. Change-event flushes are covered server-side (`_target`
// scoping) plus RefField's own blur transform; this closes the submit path.
document.addEventListener(
  "submit",
  (e) => {
    const form = e.target
    if (!form || !form.querySelectorAll) return
    const touched = []
    form.querySelectorAll('[phx-hook="RefField"]').forEach((f) => {
      const next = transformForSave(f.value, resolveRefPath)
      if (next !== f.value) {
        f.value = next
        touched.push(f)
      }
    })
    // LiveView serializes synchronously in its bubble listener, so once this
    // event settles the tokens are captured — flip the boxes straight back to
    // label form (the box must show labels, never ids; an Enter-submit keeps
    // focus in the field, which the post-patch pass deliberately skips).
    if (touched.length) {
      setTimeout(() => {
        touched.forEach((f) => {
          if (!/%<\d+>/.test(f.value)) return
          const back = rehydrate(f.value, refLabelOf)
          if (back !== f.value) f.value = back
          f.doitRefShown = back
        })
      }, 0)
    }
  },
  true // capture: precede LiveView's bubble-phase phx-submit serialization
)

// EDIT-COMMENT (Wave 3): save_comment is a native phx-submit (server-gated, and
// left that way). In CAPTURE phase — before LiveView's bubble-phase submit
// handler serializes the form (the same ordering the add-comment intercept
// above and RefField's blur transform already rely on) — rewrite the textarea's
// `%label` refs to their stored `%<id>` tokens, so the server persists the
// id-anchored form. We do NOT preventDefault: LiveView's own phx-submit still
// runs and saves the now-token value.
document.addEventListener(
  "submit",
  (e) => {
    const form = e.target.closest("[data-comment-edit-form]")
    if (!form) return
    const ta = form.querySelector("textarea[name='comment[body]']")
    if (!ta) return
    const next = transformForSave(ta.value, resolveRefPath)
    if (next !== ta.value) ta.value = next
    // The "Linked …" flash (if the ref set changed) is put by save_comment on the
    // server — no client toast. LiveView's own phx-submit persists the tokens.
  },
  true // capture: precede LiveView's bubble-phase phx-submit serialization
)

// Build a dimmed pending comment <li> mirroring the rendered row (avatar +
// header + body). Keyed by nonce so the reply can pull exactly this node.
function buildPendingComment(echoId, body, d) {
  const li = document.createElement("li")
  li.id = "comment-echo-" + echoId
  li.setAttribute("data-comment-echo", echoId)
  li.setAttribute("data-comment-pending", "")
  li.className = "group/comment text-sm opacity-60"
  const head = document.createElement("div")
  head.className = "text-xs text-zinc-500 dark:text-zinc-400 flex items-center gap-1"
  const av = document.createElement("span")
  av.className = "avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-4 h-4 text-[8px]"
  av.style.backgroundImage = (d && d.myBg) || ""
  av.style.color = (d && d.myFg) || ""
  av.textContent = (d && d.myInitials) || ""
  const meta = document.createElement("span")
  meta.textContent = ((d && d.myName) || "") + " · now"
  head.appendChild(av)
  head.appendChild(meta)
  const bodyEl = document.createElement("div")
  bodyEl.setAttribute("data-comment-body", "") // so renderAllRefs finds it (Wave 3)
  bodyEl.className = "text-zinc-800 dark:text-zinc-100 whitespace-pre-wrap"
  bodyEl.textContent = body
  li.appendChild(head)
  li.appendChild(bodyEl)
  return li
}

// Remove a pending comment bubble by nonce (reply-callback reconcile point).
function removePendingComment(echoId) {
  const n = document.getElementById("comment-echo-" + echoId)
  if (n) n.remove()
}

// DELETE-COMMENT optimistic tombstone (§6.7). The Delete button rides a native
// phx-click="delete_comment" + data-confirm: the confirm acks the click, but
// after OK the comment sits unchanged until the server re-renders the tombstone.
// Own the gesture in capture phase (like add-comment): run the SAME confirm,
// pink the comment <li> at OK, and push via DoitPush (so the dead window
// captures it too). The server's refresh_selected re-renders the tombstone and
// morphdom strips is-saving; a refused / dropped delete self-heals via
// markSaving's 1.5s timer (MUST NOT LIE). stopImmediatePropagation keeps
// LiveView's own data-confirm + phx-click from double-firing.
document.addEventListener(
  "click",
  (e) => {
    const btn = e.target.closest("[data-comment-delete]")
    if (!btn) return
    if (!window.DoitPush) return // no push channel → let the native phx-click run
    e.preventDefault()
    e.stopImmediatePropagation() // own it — no LiveView double confirm/delete
    const msg = btn.getAttribute("data-confirm") || "Delete this comment?"
    if (!window.confirm(msg)) return // declined — nothing happens
    const id = commentIdOf(btn)
    if (!id) return
    const li = document.getElementById("comment-" + id)
    if (li) markSaving([li]) // optimistic muted "deleting" cue, self-healing
    latchButton(btn, "Deleting…") // in-place cue ON the Delete control itself (§6.7)
    window.DoitPush("delete_comment", {id})
  },
  true // capture: run before LiveView's bubble-phase phx-click handler
)

// Member role-change saving hue (§6.7). The role <select> rides a native
// phx-change="update_member_role" — server-gated (the new role applies only
// after the server re-renders, broadcast via members_changed), so the native
// value flip alone leaves the wait silent. Pink the member row AND spin the
// select's adjacent busy slot at the gesture (connect-independent — pure DOM);
// the members re-render strips is-saving + the JS-added .doit-busy, and the two
// safety timers (1.5s hue, ~8s control) self-heal a dropped reply.
document.addEventListener("change", (e) => {
  const sel = e.target.closest("[data-member-role-select]")
  if (!sel) return
  const row = sel.closest("[data-member-row]")
  if (row) markSaving([row])
  setControlBusy(sel)
})

// ---------------------------------------------------------------------------
// Optimistic collaborator add (WL3 item 3.6, §6.7). The rail-menu "Add to
// {current}" is server-gated (only the Initiative's owner may add; the server
// can also report already-a-member / forbidden). We acknowledge instantly by
// inserting a dimmed pending member row, then push and reconcile on the reply:
// ok:true → the @members refresh renders the canonical row (the patch
// supersedes the stand-in); ok:false → pull the stand-in (MUST NOT LIE — they
// weren't added). Deduped by user-id so we never double a real row.
// ---------------------------------------------------------------------------
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-add-collaborator]")
  if (!btn) return
  const uid = btn.dataset.userId
  const iid = btn.dataset.initiativeId
  if (!uid || !iid) return
  // Insert a pending stand-in into every visible members list lacking a real
  // row for this user. Keyed by echo so the reply pulls exactly these.
  const echoId = "m" + Date.now() + "-" + Math.random().toString(36).slice(2, 8)
  let shownInList = false
  document.querySelectorAll("[data-members-list]").forEach((list) => {
    if (list.offsetParent === null) return // not visible — skip
    if (list.querySelector(`[data-member-row][data-user-id="${uid}"]`)) { shownInList = true; return } // already there
    list.appendChild(buildPendingMemberRow(echoId, btn.dataset))
    shownInList = true
  })
  // Fallback (Fix 5, §6.7): no members list was on-screen — on the narrow rail
  // flyout there is none, so the click went unacknowledged. Cue it IN the rail
  // (what's on-screen) by inserting the optimistic member-avatar chip into the
  // current Initiative's rail entry — the SAME railAvatarAdds path the
  // drag-collaborator-onto-initiative add uses. The `rail-avatars` applier holds
  // it across mid-flight patches; the reply (or the 8s safety) clears it.
  let railEcho = null
  if (!shownInList) {
    const a = {
      iid,
      uid,
      name: btn.dataset.userName || "",
      initials: btn.dataset.initials || "",
      bg: btn.dataset.avatarBg || "",
      fg: btn.dataset.avatarFg || "",
    }
    DoitState.railAvatarAdds[echoId] = a
    railEcho = echoId
    const row = document.getElementById("rail-avatars-" + iid)
    const group = row && row.querySelector("[data-rail-avatar-group]")
    if (group && !group.querySelector(`[data-member-id="${uid}"]`)) {
      group.appendChild(buildRailAvatarChip(echoId, a))
    }
  }
  const pull = () => {
    document.querySelectorAll(`[data-member-echo="${echoId}"]`).forEach((n) => n.remove())
    if (railEcho) {
      delete DoitState.railAvatarAdds[railEcho]
      document.querySelectorAll(`[data-rail-avatar-echo="${railEcho}"]`).forEach((n) => n.remove())
    }
  }
  if (!window.DoitPush) { pull(); return }
  // 8s safety so a dropped reply never strands the stand-in / held chip
  // (mirrors the drag-add path — MUST NOT LIE).
  const timer = setTimeout(pull, 8000)
  window.DoitPush("add_collaborator_to", {"user-id": uid, "initiative-id": iid}, (reply) => {
    // On ok the server refresh carries the real row/avatar; pull the stand-in
    // either way (success → superseded; failure → must not stand).
    clearTimeout(timer)
    pull()
    if (!reply || reply.ok === false) { if (window.DoitBonk) window.DoitBonk() }
  })
})

// A dimmed pending member row: avatar + name + @username only. Deliberately
// minimal — it never claims a role or owner-controls the server didn't grant.
function buildPendingMemberRow(echoId, d) {
  const li = document.createElement("li")
  li.setAttribute("data-member-echo", echoId)
  li.className = "flex items-center justify-between opacity-60"
  const left = document.createElement("span")
  left.className = "flex items-center gap-1 min-w-0 text-zinc-700 dark:text-zinc-200"
  const av = document.createElement("span")
  av.className = "avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-6 h-6 text-xs"
  av.style.backgroundImage = (d && d.avatarBg) || ""
  av.style.color = (d && d.avatarFg) || ""
  av.textContent = (d && d.initials) || ""
  const name = document.createElement("span")
  name.className = "truncate"
  name.textContent = (d && d.userName) || ""
  const handle = document.createElement("span")
  handle.className = "text-xs text-zinc-400 dark:text-zinc-500 truncate"
  handle.textContent = "@" + ((d && d.username) || "")
  left.appendChild(av)
  left.appendChild(name)
  left.appendChild(handle)
  li.appendChild(left)
  return li
}

// ---------------------------------------------------------------------------
// Optimistic past-collaborator prune (WL3 item 3.6, §6.7). "Remove from My
// Collaborators" (the inline confirm's Proceed) is server-gated — the server
// can refuse with :still_collaborating. We hide the rail row at once, then push
// and reconcile: ok:true → the server's rail refresh drops the row for good;
// ok:false → un-hide it (MUST NOT LIE — they weren't pruned). We hide (not
// remove) so the revert is a clean restore that survives a no-op patch.
// ---------------------------------------------------------------------------
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-prune-collaborator]")
  if (!btn) return
  const uid = btn.dataset.userId
  if (!uid) return
  const row = document.getElementById("collabrow-" + uid)
  if (row) row.hidden = true
  if (!window.DoitPush) { if (row) row.hidden = false; return }
  window.DoitPush("remove_collaborator", {"user-id": uid}, (reply) => {
    if (!reply || reply.ok === false) {
      const r = document.getElementById("collabrow-" + uid)
      if (r) r.hidden = false
    }
  })
})

// Remove-member confirm — opens client-side (the name is client-known,
// UX_GUARDRAILS 6.5). The removal itself can't be optimistic: whether the
// member holds assignments (→ a server-data hand-off modal) is server-known, so
// Proceed is a true round trip. Rather than leave the initiator hanging
// (UX_GUARDRAILS 6.7), Proceed enters a working state and the confirm stays open
// until the reply settles: {ok:true, handoff:false} or a plain commit closes it;
// {ok:true, handoff:true} closes it because the server hand-off modal has taken
// over; {ok:false} restores Proceed and surfaces the flash.
const REMOVE_MEMBER_TIMEOUT_MS = 8000
let removeMemberInFlight = false

function resetRemoveMemberModal(modal) {
  const proceed = modal && modal.querySelector("[data-remove-proceed]")
  const cancel = modal && modal.querySelector("[data-remove-cancel]")
  if (proceed) {
    proceed.classList.remove("animate-pulse", "opacity-60")
    proceed.textContent = "Remove"
  }
  if (cancel) cancel.classList.remove("pointer-events-none", "opacity-50")
  removeMemberInFlight = false
}

function pushRemoveMember(userId, onReply) {
  if (window.DoitPush && userId) window.DoitPush("remove_member", {"user-id": userId}, onReply)
}

document.addEventListener("click", (e) => {
  const modal = document.getElementById("remove-member-confirm")
  const btn = e.target.closest("[data-remove-member]")
  if (btn) {
    e.preventDefault()
    // When invoked from the rail-menu popover, preventDefault cancels the
    // button's native popover-hide — close the popover explicitly so the menu
    // doesn't linger behind the confirm.
    const pt = btn.getAttribute("popovertarget")
    if (pt) {
      const pop = document.getElementById(pt)
      if (pop && pop.matches(":popover-open")) pop.hidePopover()
    }
    if (!modal) {
      pushRemoveMember(btn.dataset.userId)
      return
    }
    resetRemoveMemberModal(modal)
    modal.dataset.userId = btn.dataset.userId
    const nameEl = modal.querySelector("[data-remove-name]")
    if (nameEl) nameEl.textContent = btn.dataset.userName || "this member"
    modal.hidden = false
    return
  }
  if (!modal || modal.hidden) return
  // Cancel / backdrop — only when not mid-flight (Cancel is disabled then).
  if (!removeMemberInFlight && (e.target === modal || e.target.closest("[data-remove-cancel]"))) {
    modal.hidden = true
    return
  }
  if (e.target.closest("[data-remove-proceed]")) {
    if (removeMemberInFlight) return
    const proceed = modal.querySelector("[data-remove-proceed]")
    const cancel = modal.querySelector("[data-remove-cancel]")
    removeMemberInFlight = true
    // Acknowledge the click instantly: the confirm stays open showing a working
    // Proceed, so nothing leaves the initiator hanging across the round trip.
    if (proceed) {
      proceed.classList.add("animate-pulse", "opacity-60")
      proceed.textContent = "Removing…"
    }
    if (cancel) cancel.classList.add("pointer-events-none", "opacity-50")
    let settled = false
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      resetRemoveMemberModal(modal) // restore Proceed; the flash (if any) covers the error
    }, REMOVE_MEMBER_TIMEOUT_MS)
    const finish = (reply) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (reply && reply.ok) {
        // Committed, or the server hand-off modal has taken over — either way
        // release this confirm; the next view (roster or hand-off modal) owns it.
        modal.hidden = true
        removeMemberInFlight = false
      } else {
        // The server refused — restore Proceed; the flash carries the reason.
        resetRemoveMemberModal(modal)
      }
    }
    pushRemoveMember(modal.dataset.userId, finish)
    if (!window.DoitPush) finish({ok: false})
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const m = document.getElementById("remove-member-confirm")
  if (m && !m.hidden && !removeMemberInFlight) m.hidden = true
})

// Client-instant transfer-ownership confirm (UX_GUARDRAILS 6.5, like the
// delete confirms): the dialog's content is client-known, so it opens at the
// click of a member's transfer (key) button — no round trip before the owner
// can decide. The button carries the target's name + id; we fill the copy and
// stash the id. Cancel / backdrop / Esc close with no consequence; only
// Proceed touches the server (confirm_transfer with the stashed id).
// The actual swap can't be optimistic — we can't honestly fake the role
// demotion client-side — so it's a true round trip (item 15.16). Rather than
// close the modal as if it succeeded, hold it open with Proceed in a working
// state until the reply settles: a repeat Proceed bonks (no second transfer),
// a timeout offers a retry, an explicit failure shows a message + a single
// Close. Only success closes the modal.
const TRANSFER_TIMEOUT_MS = 8000
let transferInFlight = false
let transferBodyHTML = null
const transferModal = () => {
  const m = document.getElementById("transfer-confirm")
  return m && !m.hidden ? m : null
}
const transferEls = () => {
  const modal = document.getElementById("transfer-confirm")
  if (!modal) return null
  return {
    modal,
    body: modal.querySelector("[data-transfer-body]"),
    proceed: modal.querySelector("[data-transfer-proceed]"),
    cancel: modal.querySelector("[data-transfer-cancel]"),
  }
}
const resetTransferModal = () => {
  const els = transferEls()
  if (!els) return
  if (transferBodyHTML !== null) els.body.innerHTML = transferBodyHTML
  els.proceed.hidden = false
  els.proceed.classList.remove("animate-pulse", "opacity-60")
  els.proceed.textContent = "Transfer ownership"
  els.cancel.classList.remove("pointer-events-none", "opacity-50")
  els.cancel.textContent = "Cancel"
  transferInFlight = false
}
const closeTransferModal = () => {
  const els = transferEls()
  if (els) els.modal.hidden = true
  transferInFlight = false
}
document.addEventListener("click", (e) => {
  const open = e.target.closest("[data-transfer-open]")
  if (open) {
    const els = transferEls()
    if (!els) return
    if (transferBodyHTML === null) transferBodyHTML = els.body.innerHTML // pristine
    resetTransferModal()
    els.modal.dataset.userId = open.dataset.userId
    const nameEl = els.modal.querySelector("[data-transfer-name]")
    if (nameEl) nameEl.textContent = open.dataset.userName || ""
    els.modal.hidden = false
    els.cancel.focus()
    return
  }
  const modal = transferModal()
  if (!modal) return
  // Proceed: latch + working state, then push with a reply callback + timeout.
  if (e.target.closest("[data-transfer-proceed]")) {
    if (transferInFlight) {
      if (window.DoitBonk) window.DoitBonk() // dropped repeat — not ignored
      return
    }
    const els = transferEls()
    if (!els) return
    transferInFlight = true
    els.proceed.classList.add("animate-pulse", "opacity-60") // stays clickable so a repeat can bonk
    els.proceed.textContent = "Transferring…"
    els.cancel.classList.add("pointer-events-none", "opacity-50")
    let settled = false
    const timer = setTimeout(() => {
      if (settled) return
      settled = true
      els.body.textContent = "Sorry, the transfer timed out — try again?"
      els.proceed.classList.remove("animate-pulse", "opacity-60")
      els.proceed.textContent = "Transfer ownership"
      els.cancel.classList.remove("pointer-events-none", "opacity-50")
      transferInFlight = false
    }, TRANSFER_TIMEOUT_MS)
    const finish = (reply) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      transferInFlight = false
      if (reply && reply.ok) {
        closeTransferModal()
      } else {
        els.body.textContent =
          "Couldn't transfer ownership — the membership may have changed. Close and try again from the current roster."
        els.proceed.hidden = true
        els.cancel.classList.remove("pointer-events-none", "opacity-50")
        els.cancel.textContent = "Close"
      }
    }
    if (window.DoitPush) {
      window.DoitPush("confirm_transfer", {"user-id": els.modal.dataset.userId}, finish)
    } else {
      finish({ok: false})
    }
    return
  }
  // Cancel / backdrop — only when not mid-flight (Cancel is disabled then).
  if (!transferInFlight && (e.target === modal || e.target.closest("[data-transfer-cancel]"))) {
    closeTransferModal()
  }
})
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = transferModal()
  if (modal && !transferInFlight) closeTransferModal()
})

// Fully-optimistic operated row (.03.07.22): a completion toggle flips the
// row's checkbox (aria-pressed), done styling (data-done), and progress bar
// at the click. The hold handle survives patches via the preserve-path `dom:`
// callbacks (the confirm's pending-hue render resets the attributes to server
// truth) and settles exactly like a held drag: revert on cancel/failure,
// release on commit/resolve.
//
// `window.DoitPendingToggle` is now a getter/setter shim backed by
// DoitState.pending.toggle (slice 2.3) so the held flip has a single source of
// truth: the immediate applyPendingToggle (called at click) and the
// KeepRegistry "pending-toggle" appliers read the same store and stay
// consistent. The shape is {liId, value, barValue, prevBarValue, sliderValue,
// prevSliderValue} — sliderValue/prevSliderValue carry the selected task's pane
// manual-slider so a leaf checkoff jumps it to 100 (or 0 on reopen) optimistically.
Object.defineProperty(window, "DoitPendingToggle", {
  get() { return DoitState.pending.toggle },
  set(v) { DoitState.pending.toggle = v },
})

function setRowBar(row, value) {
  const bar = row && row.querySelector("[role='progressbar']")
  if (!bar) return
  const v = String(value)
  if (bar.getAttribute("aria-valuenow") === v) return
  bar.style.setProperty("--progress", v + "%")
  bar.setAttribute("aria-valuenow", v)
  const txt = bar.querySelector(".progress-bar-text")
  if (txt) txt.textContent = v + "%"
}

// The selected task's pane manual-slider, when it belongs to the given li and
// is an active leaf slider (not disabled, not a branch). Returns {slider,
// readout} or null. The pane is a singleton (#task-editor-pane); the slider is
// only "this row's" when the pane is showing this task.
function paneSliderFor(li) {
  const pane = document.getElementById("task-editor-pane")
  if (!pane || pane.dataset.taskId !== li.dataset.taskId) return null
  const slider = pane.querySelector("#task-field-progress")
  if (!slider || slider.disabled) return null
  return {slider, readout: pane.querySelector("[data-progress-readout]")}
}

function applyToggleOptimism(li, toggle) {
  const row = li.querySelector(":scope > [data-task-row]")
  const bar = row && row.querySelector("[role='progressbar']")
  const done = !(toggle.getAttribute("aria-pressed") === "true")
  // The selected leaf's pane slider mirrors the bar (finding 1): the row bar
  // already jumps optimistically, but the pane's separate manual-slider control
  // did not — sync it too so checkoff feels instant in the open pane.
  const paneSlider = paneSliderFor(li)
  window.DoitPendingToggle = {
    liId: li.id,
    value: done,
    // Always knowable (.03.07.23): completing → 100, reopening → 0 — the
    // server zeroes manual_progress on every done→open transition (leaf,
    // branch, and cascade alike; see maybe_set_done_progress).
    barValue: done ? "100" : "0",
    prevBarValue: bar && bar.getAttribute("aria-valuenow"),
    // The pane slider follows the same 100/0 rule. prevSliderValue restores it
    // on a revert (cancel / failed write).
    sliderValue: paneSlider ? (done ? "100" : "0") : null,
    prevSliderValue: paneSlider ? paneSlider.slider.value : null,
  }
  applyPendingToggle()
}

function pendingToggleParts(p) {
  const li = document.getElementById(p.liId)
  const row = li && li.querySelector(":scope > [data-task-row]")
  const toggle = row && row.querySelector("[data-complete-toggle]")
  return toggle ? {row, toggle} : null
}

// Write a value onto the selected task's pane manual-slider + its readout,
// idempotently (skip a focused/dragging slider so the user's own drag isn't
// stomped; skip when the value already matches so the guard converges).
function setPaneSlider(li, value) {
  if (value == null) return
  const parts = paneSliderFor(li)
  if (!parts || parts.slider === document.activeElement) return
  const v = String(value)
  if (parts.slider.value !== v) parts.slider.value = v
  if (parts.readout && parts.readout.textContent !== v) parts.readout.textContent = v
}

function applyPendingToggle() {
  const p = window.DoitPendingToggle
  if (!p) return
  const parts = pendingToggleParts(p)
  if (!parts) return
  // Self-release once the server has BOTH committed (reply landed) AND rendered
  // the flip (live DOM shows data-done == the flip). We can't release on the
  // DOM value alone — our own optimistic write set it — so the committed flag
  // disambiguates "server confirmed" from "we faked it". This closes the
  // reply→render gap: the hold persists from the reply until the reconciling
  // render actually lands, so an interleaved patch can't revert the bar/slider.
  if (p.committed && parts.row.hasAttribute("data-done") === p.value) {
    window.DoitPendingToggle = null
    return
  }
  const want = String(p.value)
  if (parts.toggle.getAttribute("aria-pressed") !== want) {
    parts.toggle.setAttribute("aria-pressed", want)
    parts.toggle.setAttribute("aria-label", p.value ? "Reopen task" : "Mark task completed")
  }
  if (parts.row.hasAttribute("data-done") !== p.value) {
    parts.row.toggleAttribute("data-done", p.value)
  }
  if (p.barValue != null) setRowBar(parts.row, p.barValue)
  // Hold the pane slider on the optimistic value too (finding 1) so a patch
  // landing between the click and the reconciling render can't revert it.
  const li = document.getElementById(p.liId)
  if (li && p.sliderValue != null) setPaneSlider(li, p.sliderValue)
}

function revertPendingToggle() {
  const p = window.DoitPendingToggle
  window.DoitPendingToggle = null
  if (!p) return
  const parts = pendingToggleParts(p)
  if (parts) {
    parts.toggle.setAttribute("aria-pressed", String(!p.value))
    parts.toggle.setAttribute("aria-label", !p.value ? "Reopen task" : "Mark task completed")
    parts.row.toggleAttribute("data-done", !p.value)
    if (p.prevBarValue != null) setRowBar(parts.row, p.prevBarValue)
    // Restore the pane slider to what it showed before the optimistic flip.
    const li = document.getElementById(p.liId)
    if (li && p.prevSliderValue != null) setPaneSlider(li, p.prevSliderValue)
  }
  // Ancestor roll-up predictions (m03.02 item 3) revert alongside the
  // operated row — a rejected write (ok:false) or a cancelled branch-cascade
  // confirm never touches the tree server-side, so nothing else would ever
  // correct these otherwise (MUST NOT LIE: a predicted number/done-state
  // implying the toggle succeeded can't be left standing when it didn't).
  if (p.ancestorRevert) {
    p.ancestorRevert.forEach(({row, prevProgress, prevDone}) => {
      setRowBar(row, prevProgress)
      row.toggleAttribute("data-done", prevDone)
      const ancestorToggle = row.querySelector("[data-complete-toggle]")
      if (ancestorToggle) {
        ancestorToggle.setAttribute("aria-pressed", String(prevDone))
        ancestorToggle.setAttribute("aria-label", prevDone ? "Reopen task" : "Mark task completed")
      }
    })
  }
}

// Commit a completion toggle: push the event with the move_task-style reply
// contract — ok:false reverts the held optimistic flip. On a commit we DON'T
// null the handle here: the reconciling render can land a beat after the reply,
// so nulling now would let an interleaved patch revert the optimistic bar /
// slider in the gap. Instead the "pending-toggle" keep-applier releases the
// hold the moment the server-rendered data-done matches the flip (and the
// preserve-path `dom:` callbacks re-hold it on any patch until then).
// committed:false (a confirm modal is deciding) keeps holding via the same path,
// settled later by phx:confirm-cancelled/-resolved.
function pushToggleCommit(ev, li) {
  if (!window.DoitPush) return
  window.DoitPush(ev, {id: li.dataset.taskId}, (reply) => {
    if (!reply || reply.ok === false) { revertPendingToggle(); return }
    // committed:false → a confirm modal is deciding; keep holding (settled later
    // by phx:confirm-cancelled/-resolved). Otherwise mark committed so the keep-
    // appliers release the hold the moment the reconciling render lands.
    if (reply.committed !== false && window.DoitPendingToggle) {
      window.DoitPendingToggle = {...window.DoitPendingToggle, committed: true}
    }
  })
}

// Branch-cascade confirm (UX_GUARDRAILS 6.5/6.6): "complete / reopen this
// branch and all subtasks?" opens client-side — content is client-known, so no
// round trip — while the operated row's optimistic flip is held. Proceed
// commits (optionally suppressing future asks); Cancel / backdrop / Esc revert
// the flip and close. Suppression is the same localStorage key the server's
// ConfirmSkips hook syncs ("don't ask again" persists across reloads).
const CASCADE_SKIP_KEY = "doit:confirm-skip:cascade-complete"
const cascadeConfirmSuppressed = () => {
  try { return localStorage.getItem(CASCADE_SKIP_KEY) === "1" } catch (_e) { return false }
}

function openCascadeConfirm(li, ev) {
  const modal = document.getElementById("cascade-confirm")
  if (!modal) return false
  const reopen = ev === "cascade_incomplete"
  const row = li.querySelector(":scope > [data-task-row]")
  const titleEl = row && row.querySelector("[data-task-title]")
  const title = titleEl ? titleEl.textContent.trim() : "this branch"
  const body = modal.querySelector("[data-cascade-body]")
  if (body) {
    body.textContent = reopen
      ? `Reopen "${title}" and all its subtasks?`
      : `Mark "${title}" and all its subtasks complete?`
  }
  const heading = modal.querySelector("[data-cascade-title]")
  if (heading) heading.textContent = reopen ? "Reopen this branch?" : "Complete this branch?"
  const dont = modal.querySelector("[data-cascade-dont-show]")
  if (dont) dont.checked = false
  modal.dataset.cascadeEv = ev
  modal.dataset.cascadeLiId = li.id
  modal.hidden = false
  const proceed = modal.querySelector("[data-cascade-proceed]")
  if (proceed) proceed.focus()
  return true
}

function closeCascadeConfirm() {
  const modal = document.getElementById("cascade-confirm")
  if (modal) modal.hidden = true
}

document.addEventListener("click", (e) => {
  const modal = document.getElementById("cascade-confirm")
  if (!modal || modal.hidden) return
  // Cancel / backdrop — revert the held flip, close, no server touch.
  if (e.target === modal || e.target.closest("[data-cascade-cancel]")) {
    closeCascadeConfirm()
    revertPendingToggle()
    return
  }
  if (e.target.closest("[data-cascade-proceed]")) {
    const dont = modal.querySelector("[data-cascade-dont-show]")
    if (dont && dont.checked) {
      try { localStorage.setItem(CASCADE_SKIP_KEY, "1") } catch (_e) {}
    }
    const ev = modal.dataset.cascadeEv
    const li = document.getElementById(modal.dataset.cascadeLiId || "")
    closeCascadeConfirm()
    if (ev && li) pushToggleCommit(ev, li)
    else revertPendingToggle()
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = document.getElementById("cascade-confirm")
  if (modal && !modal.hidden) {
    closeCascadeConfirm()
    revertPendingToggle()
  }
})

// Large-branch-reorg confirm (UX_GUARDRAILS 6.5): "Make descendants inherit"
// predicts the descendant-branch count straight from the DOM — the whole task
// tree is rendered regardless of collapse (collapse is CSS-only) — so the
// confirm opens client-side with no round trip. Below the threshold (or
// suppressed) the cascade pushes immediately; above it, the static modal opens
// instantly while the operated subtree holds the maybe-write hue. Proceed
// commits (cascade_sort with confirmed:true, optionally persisting the skip);
// Cancel / backdrop / Esc strip the hue with no server touch. The server count
// gate stays as the authoritative backstop for a client that didn't predict.
const CASCADE_SORT_SKIP_KEY = "doit:confirm-skip:cascade-sort"
const cascadeSortSuppressed = () => {
  try { return localStorage.getItem(CASCADE_SORT_SKIP_KEY) === "1" } catch (_e) { return false }
}

// A "branch" matches the server's count_descendant_branches: a descendant that
// itself has children. In the DOM that's an li[data-task-id] containing its own
// children list (:scope > ul[id^="children-"]).
function countDescendantBranches(li) {
  return [...li.querySelectorAll('li[data-task-id]')].filter(
    (d) => d.querySelector(':scope > ul[id^="children-"]')
  ).length
}

function stripCascadeSortHue() {
  document.querySelectorAll(".is-saving, .is-recomputing").forEach((el) => {
    el.classList.remove("is-saving", "is-recomputing")
  })
}

document.addEventListener("click", (e) => {
  const trigger = e.target.closest("[data-cascade-sort]")
  if (trigger) {
    e.preventDefault()
    const id = trigger.dataset.taskId
    if (!id) return
    const li = document.querySelector(`li[data-task-id="${CSS.escape(id)}"]`)
    const modal = document.getElementById("cascade-sort-confirm")
    // The Initiative Details pane's "Make descendants inherit" targets the ROOT
    // task, which is NOT an li[data-task-id] in #task-tree — its "descendants"
    // are every task in the tree. Without this fallback the root path read 0
    // branches (so the >10 confirm was silently skipped — a §6.5 round-trip-to-
    // confirm), and no row pinked (no §6.7 cue), since the data-saving-subtree
    // listener keys off the (here-absent) selection. Scope to #task-tree so the
    // count, the maybe-write hue, and the confirm all work for the root pane too.
    const scope = li || document.getElementById("task-tree")
    const cascadeRows = () =>
      li ? savingSubtree(li) : (scope ? [...scope.querySelectorAll(SAVING_ROW)].map(savingRowOf) : [])
    const branches = scope ? countDescendantBranches(scope) : 0
    // Below threshold or suppressed → commit straight through. (Modal missing
    // also pushes — the server count gate is the backstop.)
    if (!modal || branches <= 10 || cascadeSortSuppressed()) {
      // The task pane already pinked via data-saving-subtree (it has a selected
      // row); the root pane has none, so give its at-click cue here.
      if (!li) markSaving(cascadeRows())
      if (window.DoitPush) window.DoitPush("cascade_sort", {id})
      return
    }
    // Predicted large reorg: hold the maybe-write hue on the affected rows
    // (sticky — the dialog clears it) and open the confirm instantly.
    markSaving(cascadeRows(), {sticky: true})
    const body = modal.querySelector("[data-cascade-sort-body]")
    if (body) {
      const affected = scope ? scope.querySelectorAll(SAVING_ROW).length : 0
      body.textContent =
        `This is a large branch reorg affecting ${affected} task(s). Every descendant ` +
        `branch switches to Inherit — their own sort settings are overwritten and they ` +
        `follow this branch from now on; reversible only via Undo (Arc 5).`
    }
    const dont = modal.querySelector("[data-cascade-sort-dont-show]")
    if (dont) dont.checked = false
    modal.dataset.taskId = id
    modal.hidden = false
    const proceed = modal.querySelector("[data-cascade-sort-proceed]")
    if (proceed) proceed.focus()
    return
  }
  const modal = document.getElementById("cascade-sort-confirm")
  if (!modal || modal.hidden) return
  // Cancel / backdrop — strip the hue, close, no server touch.
  if (e.target === modal || e.target.closest("[data-cascade-sort-cancel]")) {
    modal.hidden = true
    stripCascadeSortHue()
    return
  }
  if (e.target.closest("[data-cascade-sort-proceed]")) {
    const dont = modal.querySelector("[data-cascade-sort-dont-show]")
    if (dont && dont.checked) {
      try { localStorage.setItem(CASCADE_SORT_SKIP_KEY, "1") } catch (_e) {}
    }
    const id = modal.dataset.taskId
    modal.hidden = true
    if (id && window.DoitPush) {
      // The server's load_tree re-render owns the subtree from here; the hue is
      // cleared by that patch (the class is client-added, morphdom strips it),
      // but clear it explicitly so a dropped reply can't strand it.
      window.DoitPush("cascade_sort", {id, confirmed: true}, () => stripCascadeSortHue())
    } else {
      stripCascadeSortHue()
    }
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = document.getElementById("cascade-sort-confirm")
  if (modal && !modal.hidden) {
    modal.hidden = true
    stripCascadeSortHue()
  }
})

// Confirm-held optimism (§8.20): while a completion-flip confirm decides a
// drag, the optimistic placement holds. The server announces the outcome:
// "confirm-cancelled" (Cancel, click-away, or a failed Proceed) reverts the
// row to where it came from; "confirm-resolved" (modal closed via Proceed)
// releases the handle — the commit's re-render owns the row from there. A
// failed Proceed pushes both, cancelled first, so the revert still runs.
// `window.DoitPendingMove` is now a getter/setter shim backed by
// DoitState.pending.move (slice 2.3, mirroring DoitPendingToggle) so the held
// drag placement has a single source of truth: applyPendingMove reads the same
// store. Unlike the attribute-level kinds, this hold is STRUCTURAL (a subtree
// moved to a different parent), so it doesn't get a `data-keep` kind — instead
// applyPendingMove is re-run from onPatchEnd (the preserve path's post-patch
// global re-assert) after every morphdom patch.
Object.defineProperty(window, "DoitPendingMove", {
  get() { return DoitState.pending.move },
  set(v) { DoitState.pending.move = v },
})

// While a row is held away from its server-side parent, any patch touching
// that parent's list re-creates the row there (LiveView reconciles a list
// against the server's expected contents — it can't know the original node
// went elsewhere). The held original must stay the ONE instance: kill any
// same-id clone wherever a hold is asserted or released.
function removePendingMoveClones(li) {
  if (!li || !li.id) return
  document.querySelectorAll("#" + CSS.escape(li.id)).forEach((el) => {
    if (el !== li) el.remove()
  })
}

function revertPendingMove() {
  const p = window.DoitPendingMove
  window.DoitPendingMove = null
  if (!p || !p.parent || !p.parent.isConnected) return
  removePendingMoveClones(p.li)
  // The original next-sibling may have been re-rendered away; fall back to
  // appending rather than throwing.
  const next = p.next && p.next.parentElement === p.parent ? p.next : null
  p.parent.insertBefore(p.li, next)
  if (p.fabricatedUl && p.fabricatedUl.children.length === 0) p.fabricatedUl.remove()
}

// Cancel on a server confirm is client-instant (.03.07.16): the user must be
// able to hop to their next action without waiting on the round trip. Revert
// the held drag and strip the maybe-write hue at the click; cancel_pending
// reconciles the same state behind it. (A backdrop click is the overlay
// itself — the form's phx-click-away fires the same server event.)
document.addEventListener("click", (e) => {
  const overlay = document.getElementById("completion-confirm")
  if (!overlay) return
  if (e.target === overlay || e.target.closest("[data-confirm-cancel]")) {
    revertPendingMove()
    revertPendingToggle()
    document.querySelectorAll(".is-saving, .is-recomputing").forEach((el) => {
      el.classList.remove("is-saving", "is-recomputing")
    })
  }
})

// Re-assert the held placement: server-side the row still belongs to its old
// parent, so every patch that touches either child list moves it back. Runs
// from onPatchEnd; insert-only-when-different, so it converges.
function applyPendingMove() {
  const p = window.DoitPendingMove
  if (!p || !p.destContainer) return
  // A patch re-creates the row under its server-side parent as a CLONE
  // (the original sits at the held spot) — that clone is the visible
  // "snap-back". Remove clones every pass.
  removePendingMoveClones(p.li)
  // A patch may have replaced the container / sibling instances — re-find
  // them by id before giving up.
  let container = p.destContainer
  if (!container.isConnected && container.id) {
    container = document.getElementById(container.id)
    if (container) p.destContainer = container
  }
  if (!container || !container.isConnected) return
  let next = p.destNext
  if (next && !next.isConnected && next.id) next = document.getElementById(next.id)
  if (next && next.parentElement !== container) next = null
  if (p.li.parentElement !== container || p.li.nextElementSibling !== next) {
    container.insertBefore(p.li, next)
  }
}
// Backstop for the cancel paths the click listener can't see — chiefly a
// failed Proceed commit. Idempotent: the instant-cancel path already nulled
// the handles.
window.addEventListener("phx:confirm-cancelled", () => {
  revertPendingMove()
  revertPendingToggle()
})
window.addEventListener("phx:confirm-resolved", () => {
  window.DoitPendingMove = null
  window.DoitPendingToggle = null
})

// ---- Client-side completion-flip prediction for drags (UX_GUARDRAILS 6.5) --
//
// A reorganizing drag is optimistic. But when a move would silently flip an
// ancestor's completion, the confirm (sanctioned by §6.3) used to render only
// AFTER a server round trip — popping late and interrupting the user's next
// action. We now PREDICT the flip from the DOM at drop time and open the
// confirm instantly (no network wait), then re-send the move with
// confirmed: true on Proceed. The server's committed:false path (see
// handle_event "move_task") stays as the AUTHORITATIVE BACKSTOP: any flip the
// client mispredicts (false negative) still gets the old late confirm; a false
// positive is at worst an unnecessary instant confirm. Either way the DATA is
// never wrong — the server decides what actually commits.
//
// This mirrors DoIt.Tasks.classify_flips' 100-boundary intent. A leaf counts as
// "at 100" by its data-task-progress (matching computed_progress), NOT data-done
// (status, which can lag the progress recompute by a beat).
//
// Returns null (no predicted flip) or {scenario, titles}:
//   scenario 1 = only "would uncomplete", 2 = only "would complete", 3 = both.

// True when `li` is a leaf: no non-empty descendant task <li>. (A fabricated
// empty <ul> shell carries no <li>, so it doesn't make a parent a branch.)
function moveLiIsLeaf(li) {
  return !li.querySelector("li[data-task-id]")
}

// Every descendant leaf <li> of `li` — or `li` itself if it's already a leaf.
function moveLeavesOf(li) {
  if (moveLiIsLeaf(li)) return [li]
  return [...li.querySelectorAll("li[data-task-id]")].filter(moveLiIsLeaf)
}

// A leaf is "at 100" by its row's data-task-progress (mirrors computed_progress).
function moveLeafAt100(leafLi) {
  const row = leafLi.querySelector(":scope > [data-task-row]")
  return !!row && row.getAttribute("data-task-progress") === "100"
}

// The chain of visible ancestor <li>s from `li`'s parent up to (not incl.) the
// root <ul> — the system root (the initiative) is not a visible <li>, so it's
// never in this list and never flipped.
function moveAncestorChain(li) {
  const chain = []
  let cur = li.parentElement && li.parentElement.closest("li[data-task-id]")
  while (cur) {
    chain.push(cur)
    cur = cur.parentElement && cur.parentElement.closest("li[data-task-id]")
  }
  return chain
}

// Open leaves currently under ancestor `li` (progress !== 100).
function moveOpenLeavesUnder(li) {
  return moveLeavesOf(li).filter((leaf) => !moveLeafAt100(leaf))
}

function moveTitleOf(li) {
  const t = li.querySelector(":scope > [data-task-row] [data-task-title]")
  return t ? t.textContent.trim() : ""
}

// Predict whether moving `draggedLi` out of `sourceParentLi` and into
// `destParentLi` would flip any visible ancestor's completion. Read from the
// ORIGINAL tree (call before the optimistic DOM move).
function predictMoveFlip(draggedLi, sourceParentLi, destParentLi) {
  // Same parent → a sibling reorder. ProductSpec: reordering doesn't change the
  // math, so no ancestor's completion can flip. (Covers the null===null case of
  // two top-level siblings too.)
  if (sourceParentLi === destParentLi) return null

  // Leaves carried by the move, and whether any of them is open.
  const movedLeaves = new Set(moveLeavesOf(draggedLi))
  const movedHasOpen = [...movedLeaves].some((leaf) => !moveLeafAt100(leaf))

  // Ancestors at/above the lowest common ancestor (LCA) are unaffected: the
  // subtree stays within them, so their leaf set is unchanged. Only ancestors
  // STRICTLY BELOW the LCA on each chain can flip.
  const sourceChain = sourceParentLi ? moveAncestorChain(draggedLi) : []
  const destChain = destParentLi ? [destParentLi, ...moveAncestorChain(destParentLi)] : []
  const destSet = new Set(destChain)
  // The LCA is the first source-chain ancestor that's also on the dest chain.
  const lca = sourceChain.find((a) => destSet.has(a)) || null
  const belowLca = (chain) => {
    const i = lca ? chain.indexOf(lca) : -1
    return i === -1 ? chain : chain.slice(0, i)
  }
  const sourceBelow = belowLca(sourceChain)
  const destBelow = belowLca(destChain)

  let complete = false // some open ancestor becomes all-done (source side)
  let uncomplete = false // some all-done ancestor gains an open leaf (dest side)
  const titles = []

  // Source-chain ancestor A flips COMPLETE iff A currently has ≥1 open leaf AND
  // every one of A's open leaves is within movedLeaves (removing the subtree
  // leaves A all-done).
  for (const a of sourceBelow) {
    const open = moveOpenLeavesUnder(a)
    if (open.length > 0 && open.every((leaf) => movedLeaves.has(leaf))) {
      complete = true
      titles.push(moveTitleOf(a))
    }
  }

  // Dest-chain ancestor A flips UNCOMPLETE iff A is currently all-done (no open
  // leaves) AND the moved subtree brings an open leaf.
  if (movedHasOpen) {
    for (const a of destBelow) {
      if (moveOpenLeavesUnder(a).length === 0) {
        uncomplete = true
        titles.push(moveTitleOf(a))
      }
    }
  }

  if (!complete && !uncomplete) return null
  const scenario = complete && uncomplete ? 3 : uncomplete ? 1 : 2
  return {scenario, titles: titles.filter((t) => t)}
}

// The instant move-flip confirm. Mirrors the client-opened delete confirm: the
// #move-flip-confirm modal is always rendered (hidden, phx-update="ignore") so
// the server never clobbers it; app.js fills its scenario message + flipping
// titles and shows it. Cancel/backdrop/Esc revert the held optimistic
// placement (§6.6 — optimism holds until the user decides); Proceed pushes
// move_task with confirmed:true. This NEVER touches the server-rendered
// #completion-confirm backstop.
//
// Wording matches the server confirm copy so both read consistently:
//   title  = "Confirm completion change"   (confirm_title fallback)
//   body   = completion_confirm_message(scenario, "move")
const MOVE_FLIP_MESSAGES = {
  1: "This move will mark previously completed task(s) as incomplete.",
  2: "This move will mark previously incomplete task(s) as complete.",
  3: "This move will mark some tasks complete and others incomplete.",
}

function moveFlipModal() {
  const m = document.getElementById("move-flip-confirm")
  return m && !m.hidden ? m : null
}

// Open the modal with the predicted scenario + flipping titles. The optimistic
// placement has already happened and DoitPendingMove holds the revert handle;
// the saving hue stays (sticky) while the modal decides.
function openMoveFlipConfirm(prediction) {
  const modal = document.getElementById("move-flip-confirm")
  if (!modal) return false
  const msg = modal.querySelector("[data-flip-message]")
  if (msg) msg.textContent = MOVE_FLIP_MESSAGES[prediction.scenario] || ""
  const list = modal.querySelector("[data-flip-titles]")
  if (list) {
    list.innerHTML = ""
    if (prediction.titles.length === 0) {
      list.hidden = true
    } else {
      list.hidden = false
      prediction.titles.forEach((title) => {
        const li = document.createElement("li")
        li.className = "truncate"
        li.textContent = title
        list.appendChild(li)
      })
    }
  }
  modal.hidden = false
  const cancel = modal.querySelector("[data-flip-cancel]")
  if (cancel) cancel.focus()
  return true
}

// Clear the create-flip markers stashed on the reused #move-flip-confirm.
function clearCreateFlipMarkers(modal) {
  if (!modal) return
  delete modal.dataset.createFlip
  delete modal.dataset.createTitle
  delete modal.dataset.createParentId
  delete modal.dataset.createAfterId
}

// Cancel / backdrop / Esc: revert the held placement (move) or drop the preview
// row (create) and strip the saving hue.
function closeMoveFlipConfirmCancel() {
  const modal = document.getElementById("move-flip-confirm")
  if (modal) modal.hidden = true
  if (modal && modal.dataset.createFlip) {
    // Create flip cancelled: the task never gets created — drop its preview row.
    dropPendingRows()
    clearCreateFlipMarkers(modal)
  } else {
    revertPendingMove()
  }
  document.querySelectorAll(".is-saving, .is-recomputing").forEach((el) => {
    el.classList.remove("is-saving", "is-recomputing")
  })
}

document.addEventListener("click", (e) => {
  // Open is triggered by the drag handler, not a click — only Cancel/Proceed/
  // backdrop are handled here.
  const modal = moveFlipModal()
  if (!modal) return
  if (e.target === modal || e.target.closest("[data-flip-cancel]")) {
    closeMoveFlipConfirmCancel()
    return
  }
  if (e.target.closest("[data-flip-proceed]")) {
    modal.hidden = true
    const stripHue = () =>
      document.querySelectorAll(".is-saving, .is-recomputing").forEach((el) => {
        el.classList.remove("is-saving", "is-recomputing")
      })
    // Create flip: re-submit the create, now confirmed — the server commits
    // straight through and its load_tree re-render reconciles the preview row.
    if (modal.dataset.createFlip) {
      pushCreateTask(
        modal.dataset.createTitle,
        modal.dataset.createParentId,
        modal.dataset.createAfterId,
        true
      )
      clearCreateFlipMarkers(modal)
      stripHue()
      return
    }
    const handle = window.DoitPendingMove
    // Re-send the move, now confirmed — the server commits straight through.
    if (window.DoitPush && handle && handle.moveParams) {
      const params = {...handle.moveParams, confirmed: true}
      window.DoitPush("move_task", params, (reply) => {
        const failed = !reply || reply.ok === false
        if (failed) {
          // The server refused after all — snap back.
          revertPendingMove()
        } else {
          // Committed: the placement is truth; release the hold.
          window.DoitPendingMove = null
        }
        stripHue()
      })
    } else {
      // No push channel — fall back to a snap-back rather than a lying success.
      revertPendingMove()
      stripHue()
    }
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  if (moveFlipModal()) closeMoveFlipConfirmCancel()
})

// --- §6.8 dead-window capture: native phx-* interceptor (WL4.2.2) -----------
//
// The queue above captures only server-gated writes that funnel through
// window.DoitPush. Many server-gated actions never touch DoitPush — they ride
// NATIVE phx-click / phx-submit / phx-change and LiveView pushes them itself
// (inline update_task + the progress slider, branch set_sort, the Assigned
// reveal / group-by prefs, Archived toggle_show_hidden + hide/unhide/restore,
// set_index_style, settings subtitle / progress-calc / viewer+, the common
// add-task submit, save-comment, member-role, …). Before the view is live those
// native pushes are silently dropped — the §6.8 dead window. This document-level
// CAPTURE-phase interceptor closes that gap: while the view is dead
// (livePush === null) it serializes the LiveView event INTENT off the gesture
// and routes it through the SAME queue (enqueuePreconnect), so it flushes in
// order on connect through the existing funnel. Once live it is a pure no-op —
// the early `if (livePush) return` bails before any work, so LiveView handles
// everything natively with zero steady-state effect.
//
// We SERIALIZE, we do NOT re-dispatch: on connect the queued intents flush via
// pushEvent (a "hook"-type push whose payload is the literal object), NOT by
// re-firing click / submit — the optimistic client handlers already ran at the
// real gesture, so re-dispatching would double-apply them. We capture only the
// server event NAME + PAYLOAD at the moment of the gesture and replay that.
//
// De-confliction (never double-send): an action already delivered by DoitPush
// must not also be captured here. DOITPUSH_OWNED lists every DoitPush event
// name; the interceptor skips them. create_task is intentionally NOT in that set
// — see the submit handler. Registration ORDER matters: this block installs
// AFTER the #add-task-form (create) and #add-comment capture listeners, so their
// stopImmediatePropagation() — fired only on the paths where DoitPush takes
// over — suppresses this interceptor for those gestures, leaving the no-flip
// add-task submit (which has no DoitPush) for us to capture.

// Event names DoitPush already delivers (so the dead window already captures
// them) — derived from the DoitPush(...) call sites. Skipped here to avoid a
// double send. toggle_complete / the cascades have no phx-* of their own (they
// ride data-toggle-event) but are listed for completeness / future-proofing.
const DOITPUSH_OWNED = new Set([
  "select_task", "close_task",
  "delete_task", "delete_initiative", "leave_initiative",
  "cancel_handoff", "archive_initiative", "confirm_transfer",
  "add_comment", "delete_comment", "add_collaborator_to", "remove_collaborator", "remove_member",
  "cascade_sort", "move_task",
  "toggle_complete", "cascade_complete", "cascade_incomplete",
])

// Irreversible actions whose confirmation lives OUTSIDE this capture, so they
// must never be auto-replayed across the dead window: a `data-confirm` click
// (its LiveView confirm dialog can't run while dead — caught inline below) and
// account deletion (gated by a details-expand, but too destructive to fire on
// connect without a live re-confirm). The user simply re-acts once the badge
// clears — a dropped re-confirmable click is the safe failure here.
const PRECONNECT_DESTRUCTIVE = new Set(["delete_account"])

// LiveView nested-form params, replicated (WL4.2.2). A native phx-change /
// phx-submit serializes the whole form to a urlencoded string the server decodes
// (Plug.Conn.Query) into a NESTED map: name="task[title]" => %{"task" =>
// %{"title" => v}}. Because we replay through pushEvent (payload = literal
// object) rather than the native "form" event, the object built HERE must equal
// what the server would have decoded, or the handler sees the wrong shape. This
// walks new FormData(form) and rebuilds that object from bracket notation,
// matching Plug.Conn.Query: `name[]` => list append, duplicate flat key => last
// wins, and DISABLED / unchecked controls are simply absent (FormData omits
// them, exactly like the wire form — so an off viewer_plus sends no key, a
// branch task's disabled slider sends none, same as native).
function preconnectParseName(name) {
  // "task[title]" -> ["task","title"]; "a[b][]" -> ["a","b",""]; "mode" -> ["mode"].
  const i = name.indexOf("[")
  if (i === -1) return [name]
  const parts = [...name.slice(i).matchAll(/\[([^\]]*)\]/g)].map((m) => m[1])
  return [name.slice(0, i), ...parts]
}
function preconnectSetPath(root, path, value) {
  let node = root
  for (let k = 0; k < path.length - 1; k++) {
    const seg = path[k] === "" ? node.length : path[k]
    if (node[seg] == null || typeof node[seg] !== "object") {
      node[seg] = path[k + 1] === "" ? [] : {}
    }
    node = node[seg]
  }
  const last = path[path.length - 1]
  if (last === "") node.push(value) // `name[]` -> array append
  else node[last] = value // last-wins for a duplicate flat / nested key
}
function preconnectSerializeForm(form) {
  const out = {}
  for (const [name, value] of new FormData(form).entries()) {
    preconnectSetPath(out, preconnectParseName(name), value)
  }
  return out
}
// The pane's two update_task forms carry NO task id — natively the server
// applies them to its loaded selection. A dead-window edit, though, flushes on
// connect BEFORE the .TaskKeys selection replay lands (DoitRegisterLivePush runs
// ahead of the select_task push), so "current selection" is stale/nil at flush.
// Capture the task this edit was made against (DoitState.selectedId) into the
// payload so it ALWAYS lands on its own task — the server honors payload.id when
// present and falls back to selected_task otherwise (WL4.2.2 Defect 2). The
// coalesce key folds the id in, so cross-task dead-window edits never collide.
function preconnectSelfTarget(ev, payload) {
  if (ev === "update_task" && DoitState.selectedId != null) {
    payload.id = String(DoitState.selectedId)
  }
  return payload
}
// phx-value-* attributes -> payload (strip the prefix), mirroring LiveView's
// phx-click value serialization (phx-value-id="3" => {id: "3"}).
function preconnectClickPayload(el) {
  const payload = {}
  for (const a of el.attributes) {
    if (a.name.startsWith("phx-value-")) payload[a.name.slice("phx-value-".length)] = a.value
  }
  return payload
}
// True for a JS-command binding (e.g. phx-click={JS.toggle(...)} or JS.push(...)):
// the attribute is a serialized command array ("[[...]]"), not a plain server
// event name, so it can't be replayed as one. Skipped (and logged) — see report.
function preconnectIsJsCommand(raw) {
  return !raw || raw[0] === "["
}

// phx-click: event name = the attribute; payload = the phx-value-* map.
document.addEventListener("click", (e) => {
  if (livePush) return
  const el = e.target.closest("[phx-click]")
  if (!el) return
  const ev = el.getAttribute("phx-click")
  if (preconnectIsJsCommand(ev)) {
    if (ev) console.debug("[preconnect] skipping JS-command phx-click:", ev)
    return
  }
  if (DOITPUSH_OWNED.has(ev) || PRECONNECT_DESTRUCTIVE.has(ev)) return
  if (el.hasAttribute("data-confirm")) return // confirm can't run while dead — don't auto-fire
  enqueuePreconnect(ev, preconnectClickPayload(el))
}, true)

// phx-submit: event name = the form's binding; payload = the serialized form
// (plus the submitter's name/value, which LiveView includes). preventDefault so
// a dead-window submit can't trigger a native full-page POST / navigation.
document.addEventListener("submit", (e) => {
  if (livePush) return
  const form = e.target
  const ev = form && form.getAttribute && form.getAttribute("phx-submit")
  if (!ev || preconnectIsJsCommand(ev) || DOITPUSH_OWNED.has(ev)) return
  e.preventDefault()
  const payload = preconnectSerializeForm(form)
  if (e.submitter && e.submitter.name) {
    preconnectSetPath(payload, preconnectParseName(e.submitter.name), e.submitter.value || "")
  }
  enqueuePreconnect(ev, preconnectSelfTarget(ev, payload))
}, true)

// phx-change: event name = the input's binding or its form's (mirrors LiveView,
// which honors an input-level phx-change over the form's); payload = the
// serialized form plus _target = the changed field's name (LiveView sends it to
// scope validation; no handler here reads it, included for parity). Bound on
// BOTH input and change (LiveView listens to both); coalescing per form means
// the duplicate is harmless — the latest full-form snapshot wins.
function preconnectCapturePhxChange(e) {
  if (livePush) return
  const input = e.target
  if (!input || !input.getAttribute) return
  const ev = input.getAttribute("phx-change") || (input.form && input.form.getAttribute("phx-change"))
  if (!ev || preconnectIsJsCommand(ev) || DOITPUSH_OWNED.has(ev)) return
  const form = input.form
  if (!form) return
  const payload = preconnectSerializeForm(form)
  payload._target = input.name || ""
  enqueuePreconnect(ev, preconnectSelfTarget(ev, payload))
}
document.addEventListener("input", preconnectCapturePhxChange, true)
document.addEventListener("change", preconnectCapturePhxChange, true)

// Confirmation suppression (.03.01.11): read the per-class skip flags from
// localStorage on mount and push them to the LiveView; persist a flag when the
// server reports a "Don't show this again" box was checked on Proceed.
const CONFIRM_CLASSES = ["completion-flip", "cascade-sort", "cascade-complete"]
Hooks.ConfirmSkips = {
  mounted() {
    ensureStorageVersion("doit:confirm-skip", 1)
    const skipped = CONFIRM_CLASSES.filter(
      (c) => localStorage.getItem("doit:confirm-skip:" + c) === "1"
    )
    this.pushEvent("confirm_skips_loaded", {classes: skipped})
    this.handleEvent("persist-confirm-skip", (payload) => {
      localStorage.setItem("doit:confirm-skip:" + payload.class, "1")
    })
  },
}

// Auto-dismiss :info flash messages after 4s. :error flashes stay until the
// user dismisses them (those usually need attention).
Hooks.AutoDismissFlash = {
  mounted() {
    if (this.el.dataset.kind === "info") {
      this.timer = setTimeout(() => this.el.click(), 4000)
    }
  },
  destroyed() {
    if (this.timer) clearTimeout(this.timer)
  },
}

// Mobile theme toggle: one icon for the current theme; click cycles
// system → light → dark. Mirrors the desktop group — dispatches phx:set-theme
// (client theme + localStorage) and pushes set_theme for server persistence.
const THEME_ORDER = ["system", "light", "dark"]
Hooks.ThemeCycle = {
  mounted() {
    // Marks this control hook-managed so the global dead-view cycle fallback
    // (above) stands down once we're live — otherwise both would fire and skip
    // a step. Removed on destroy so the fallback owns it again on a dead view.
    this.el.dataset.themeHooked = "true"
    this.sync()
    this.onClick = () => this.cycle()
    this.el.addEventListener("click", this.onClick)
    this.onStorage = (e) => { if (e.key === "phx:theme") this.sync() }
    window.addEventListener("storage", this.onStorage)
  },
  destroyed() {
    delete this.el.dataset.themeHooked
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("storage", this.onStorage)
  },
  themeState() {
    return localStorage.getItem("phx:theme") || "system"
  },
  sync() {
    const cur = this.themeState()
    this.el.querySelectorAll("[data-theme-icon]").forEach((s) => {
      s.classList.toggle("hidden", s.dataset.themeIcon !== cur)
    })
  },
  cycle() {
    const next = THEME_ORDER[(THEME_ORDER.indexOf(this.themeState()) + 1) % THEME_ORDER.length]
    window.dispatchEvent(new CustomEvent("phx:set-theme", { detail: { theme: next } }))
    this.pushEvent("set_theme", { theme: next })
    this.sync()
  },
}

// Drag-and-drop reorganization for tasks. Attached to each row's drag handle.
// Uses pointer events (not HTML5 drag-and-drop) so the same gesture loop
// works for mobile (item 8) and the cross-pane gesture in Arc 4 item 11.
//
// State machine:
//
//   IDLE
//     -- pointerdown on handle --> ARMED  (capture origin, no UI change yet)
//   ARMED
//     -- pointermove past 4px threshold --> DRAGGING (mount overlay UI)
//     -- pointerup before threshold --> IDLE  (treated as click, no event)
//     -- pointercancel / Escape --> IDLE
//   DRAGGING
//     -- pointermove --> resolve the row under the cursor as the anchor
//     -- pointerup over a valid anchor --> push "move_task" event, then IDLE
//     -- pointerup over source / descendant / no row --> IDLE (no commit)
//     -- pointercancel / Escape --> IDLE (no commit)
//
// Drop-target resolution (item 15 drop bands):
//
//   elementFromPoint picks the row under the cursor — the anchor. Which
//   vertical band of that row the cursor is in decides the gesture:
//     - top 25%    → sibling reorder ABOVE the anchor
//     - middle 50% → reparent: source becomes a child of the anchor
//     - bottom 25% → sibling reorder BELOW the anchor
//   Reparent appends to the anchor's children. Sibling reorders carry an
//   explicit position plus a `reorder` flag (item 16: the server pins the
//   destination container to manual sort so the placement sticks). Anchor =
//   source row, a descendant of source, or no row → no commit; horizontal
//   cursor position is ignored. A center drop onto the source's own parent
//   is a no-op (already a child) and shows the forbidden signifier — but
//   that same row's edge bands stay valid (reorder relative to the parent).
//   Two root-level overlay zones (item 17) bracket the root list during a
//   drag and take priority over row anchoring: a hit promotes a non-root
//   source to, or reorders a root source within, the top/bottom of the list.
const DRAG_THRESHOLD_PX = 4 // mouse/pen must move this far before drag activates
const LONG_PRESS_MS = 400 // touch must hold this long without significant motion to begin drag
const TOUCH_MOVE_TOLERANCE_PX = 8 // touch jitter allowed during the long-press wait before we treat it as scroll
const EDGE_SCROLL_ZONE_PX = 64 // dragging within this many px of the scroll container's top/bottom edge auto-scrolls
const EDGE_SCROLL_MAX_PX = 16 // max auto-scroll step per animation frame, at the very edge

Hooks.DragReorder = {
  mounted() {
    this.onPointerDown = (e) => this.startArm(e)
    this.el.addEventListener("pointerdown", this.onPointerDown)
  },
  destroyed() {
    this.cleanup()
    if (this.onPointerDown) this.el.removeEventListener("pointerdown", this.onPointerDown)
  },

  // ---- Phase 1: ARMED ----------------------------------------------------
  // We don't commit to "this is a drag" until the user signals intent. For
  // mouse/pen that's movement past DRAG_THRESHOLD_PX. For touch it's a
  // ~400 ms hold without significant movement (long-press) — short taps and
  // swipes/scrolls on the handle stay no-ops. This avoids hijacking simple
  // clicks AND avoids stealing scroll gestures from the page on mobile.
  startArm(e) {
    if (e.button !== undefined && e.button !== 0) return // left button only
    // Multi-touch: only the first pointer arms. Ignore any pointer that
    // arrives while we're already engaged (armed or dragging).
    if (this.armed || this.dragging) return
    e.preventDefault()
    e.stopPropagation() // prevent row's phx-click="select_task"

    this.startX = e.clientX
    this.startY = e.clientY
    this.pointerType = e.pointerType || "mouse"
    this.activePointerId = e.pointerId
    this.armed = true
    this.dragging = false
    // For touch, ARMED splits into "waiting for long-press" (longPressFired
    // = false) and "long-press fired, waiting for first move or up"
    // (longPressFired = true). Mouse/pen skip this and go straight to
    // movement-threshold promotion — longPressFired stays true so any
    // first move past DRAG_THRESHOLD_PX promotes via the normal path.
    this.longPressFired = this.pointerType !== "touch"

    this.onMove = (ev) => this.handleMove(ev)
    this.onUp = (ev) => this.handleUp(ev)
    this.onCancel = () => this.abort()
    this.onKeyDown = (ev) => { if (ev.key === "Escape") this.abort() }

    document.addEventListener("pointermove", this.onMove)
    document.addEventListener("pointerup", this.onUp)
    document.addEventListener("pointercancel", this.onCancel)
    document.addEventListener("keydown", this.onKeyDown)

    if (this.pointerType === "touch") {
      // Visual cue: handle scales up while the long-press timer counts.
      // motion-safe:* keeps the smooth easing for users who allow motion;
      // under prefers-reduced-motion the scale snaps in instantly, which
      // still gives static feedback.
      this.el.classList.add(
        "scale-110",
        "motion-safe:transition-transform",
        "motion-safe:duration-200",
      )
      this.longPressTimer = setTimeout(() => {
        this.longPressTimer = null
        if (!this.armed || this.dragging) return
        this.longPressFired = true
        this.clearPrimingCue()
        this.beginDrag()
      }, LONG_PRESS_MS)
    }
  },

  clearLongPressTimer() {
    if (this.longPressTimer) {
      clearTimeout(this.longPressTimer)
      this.longPressTimer = null
    }
  },

  clearPrimingCue() {
    this.el.classList.remove(
      "scale-110",
      "motion-safe:transition-transform",
      "motion-safe:duration-200",
    )
  },

  // ---- Phase 2: DRAGGING -------------------------------------------------
  beginDrag() {
    this.dragging = true

    // Source row reference + visual affordance.
    this.sourceLi = this.el.closest("li[data-task-id]")
    if (this.sourceLi) {
      this.sourceLi.classList.add("dragging-source")
    }

    // Cache initiative id from the handle's data attribute. All tasks in
    // the tree share the same initiative id.
    this.initiativeId = this.el.dataset.initiativeId

    document.body.style.userSelect = "none"
    document.body.style.cursor = "grabbing"

    this.mountRootZones()

    // Edge auto-scroll: cache the scroll container and run a loop that scrolls
    // it while the pointer sits near its top/bottom edge — so drops onto
    // off-screen rows are reachable without letting go.
    this.scrollEl = this.scrollContainer()
    this.startEdgeScroll()
  },

  handleMove(e) {
    if (!this.armed) return
    // Multi-touch: ignore movement from pointers other than the one that armed.
    if (this.activePointerId !== undefined && e.pointerId !== undefined &&
        e.pointerId !== this.activePointerId) return

    if (!this.dragging) {
      const dx = e.clientX - this.startX
      const dy = e.clientY - this.startY
      const dist = Math.hypot(dx, dy)

      if (this.pointerType === "touch" && !this.longPressFired) {
        // Pre-long-press: significant motion = the user is scrolling /
        // swiping, not priming a drag. Cancel and fully release the
        // gesture so the browser can take over.
        if (dist >= TOUCH_MOVE_TOLERANCE_PX) {
          this.maybeDragHint()
          this.abort()
        }
        return
      }

      // Mouse/pen: small movement threshold avoids promoting on a jittery
      // click. (Touch reaches here only if a stray move event slipped in
      // after the timer fired but before beginDrag set dragging=true; the
      // beginDrag call below is idempotent for that race.)
      if (dist < DRAG_THRESHOLD_PX) return
      this.beginDrag()
    }

    this.lastClientX = e.clientX
    this.lastClientY = e.clientY
    this.updateDropTarget(e.clientX, e.clientY)
  },

  // Resolve what a drop at (clientX, clientY) would do: update the highlight /
  // forbidden signifiers and this.dropPlan. Called on every pointermove and —
  // so a pointer held still inside an edge-scroll zone keeps tracking the rows
  // sliding under it — on each auto-scroll frame.
  updateDropTarget(clientX, clientY) {
    this.clearAnchorHighlight()

    // Root-level overlay zones (item 17) take priority over row anchoring.
    // A hit promotes a non-root source to the root list, or reorders a root
    // source within it: top zone → front, bottom zone → end. Either way the
    // destination is the root list, flagged reorder (item 16 pins the
    // Initiative to manual).
    const zone = this.rootZoneAt(clientX, clientY)
    if (zone) {
      this.clearForbidden()
      this.anchorLi = null
      this.setZoneActive(zone)
      this.dropPlan = {
        parentId: null,
        position: zone === this.topZone ? 0 : null,
        reorder: true,
      }
      return
    }

    // Anchor = the row under the cursor. Hide the source briefly so
    // elementFromPoint skips it (otherwise we'd always anchor on ourselves
    // when the cursor stays near the source row).
    const prev = this.sourceLi.style.pointerEvents
    this.sourceLi.style.pointerEvents = "none"
    const target = document.elementFromPoint(clientX, clientY)
    this.sourceLi.style.pointerEvents = prev || ""

    // Tail zone (item 21) → drop as the LAST child of that branch. Takes
    // priority over row anchoring; the strip sits inside the branch's child
    // <ul>, so it's only reachable when the branch is expanded.
    const tailLi = target && target.closest("li.drop-tail")
    if (tailLi) {
      const branchLi = tailLi.closest("li[data-task-id]")
      if (!branchLi || branchLi === this.sourceLi || this.isDescendantOfSource(branchLi)) {
        this.anchorLi = null
        this.dropPlan = null
        if (branchLi) this.setForbidden(branchLi)
        return
      }
      this.clearForbidden()
      this.anchorLi = null
      this.setTailActive(tailLi)
      this.dropPlan = {
        parentId: parseInt(branchLi.dataset.taskId, 10),
        position: this.lastChildPosition(branchLi),
        reorder: true,
      }
      return
    }

    const anchorLi = target && target.closest("li[data-task-id]")
    if (!anchorLi || anchorLi === this.sourceLi || this.isDescendantOfSource(anchorLi)) {
      this.clearForbidden()
      this.anchorLi = null
      this.dropPlan = null
      return
    }

    // Which vertical band of the row the cursor is in decides the gesture
    // (item 15). Measured against the row strip only, not the subtree.
    const band = this.bandFor(anchorLi, clientY)

    if (band === "center") {
      // Center drop onto the source's own parent is a no-op (already a
      // child). Show the forbidden signifier instead of committing.
      if (anchorLi === this.sourceParentLi()) {
        this.setForbidden(anchorLi)
        this.anchorLi = null
        this.dropPlan = null
        return
      }

      this.clearForbidden()
      this.anchorLi = anchorLi
      this.anchorLi.classList.add("drop-target")
      this.dropPlan = {
        parentId: parseInt(anchorLi.dataset.taskId, 10),
        position: null,
        reorder: false,
      }
      return
    }

    // Edge band → sibling reorder above/below the anchor. Destination parent
    // is the anchor's parent; position is the anchor's index among its
    // siblings (adjusted for the source when they share that parent).
    this.clearForbidden()
    this.anchorLi = anchorLi
    this.dropPlan = {
      parentId: this.anchorParentId(anchorLi),
      position: this.siblingPosition(anchorLi, band),
      reorder: true,
    }
    this.showPlaceholder(anchorLi, band)
  },

  // The nearest scrollable ancestor of the dragged row — normally
  // <main class="flex-1 overflow-y-auto">. Falls back to the document scroller.
  scrollContainer() {
    let el = this.el.parentElement
    while (el) {
      const oy = getComputedStyle(el).overflowY
      if ((oy === "auto" || oy === "scroll") && el.scrollHeight > el.clientHeight) return el
      el = el.parentElement
    }
    return document.scrollingElement || document.documentElement
  },

  startEdgeScroll() {
    if (this.edgeRAF) return
    const tick = () => {
      if (!this.dragging) { this.edgeRAF = null; return }
      this.edgeScrollStep()
      this.edgeRAF = requestAnimationFrame(tick)
    }
    this.edgeRAF = requestAnimationFrame(tick)
  },

  // Scroll the container when the pointer sits within EDGE_SCROLL_ZONE_PX of
  // its top/bottom edge; speed ramps with depth into the zone. After a scroll,
  // re-resolve the drop target so the highlight tracks rows sliding under a
  // pointer that isn't moving.
  edgeScrollStep() {
    const el = this.scrollEl
    if (!el || this.lastClientY == null) return

    const docScroller = el === document.scrollingElement ||
      el === document.documentElement || el === document.body
    const rect = docScroller ? null : el.getBoundingClientRect()
    const top = docScroller ? 0 : rect.top
    const bottom = docScroller ? window.innerHeight : rect.bottom

    const y = this.lastClientY
    let delta = 0
    if (y < top + EDGE_SCROLL_ZONE_PX) {
      const f = Math.min((top + EDGE_SCROLL_ZONE_PX - y) / EDGE_SCROLL_ZONE_PX, 1)
      delta = -Math.ceil(EDGE_SCROLL_MAX_PX * f)
    } else if (y > bottom - EDGE_SCROLL_ZONE_PX) {
      const f = Math.min((y - (bottom - EDGE_SCROLL_ZONE_PX)) / EDGE_SCROLL_ZONE_PX, 1)
      delta = Math.ceil(EDGE_SCROLL_MAX_PX * f)
    }
    if (!delta) return

    const before = el.scrollTop
    el.scrollTop = before + delta
    if (el.scrollTop !== before) this.updateDropTarget(this.lastClientX, this.lastClientY)
  },

  sourceParentLi() {
    return (this.sourceLi && this.sourceLi.parentElement &&
            this.sourceLi.parentElement.closest("li[data-task-id]")) || null
  },

  setForbidden(li) {
    if (this.forbiddenLi && this.forbiddenLi !== li) {
      this.forbiddenLi.classList.remove("drop-forbidden")
    }
    this.forbiddenLi = li
    li.classList.add("drop-forbidden")
    document.body.style.cursor = "not-allowed"
  },

  clearForbidden() {
    if (this.forbiddenLi) {
      this.forbiddenLi.classList.remove("drop-forbidden")
      this.forbiddenLi = null
    }
    document.body.style.cursor = ""
  },

  // ---- Phase 3: COMMIT / ABORT -------------------------------------------
  handleUp(e) {
    if (!this.armed) return
    // Multi-touch: only the original pointer's release ends the gesture.
    if (this.activePointerId !== undefined && e.pointerId !== undefined &&
        e.pointerId !== this.activePointerId) return
    if (!this.dragging) {
      // Tap on handle (mouse click without drag, or touch released before
      // long-press timer fired) — no-op. cleanup() also clears the timer.
      this.cleanup()
      return
    }

    // pointerup is followed by a synthetic click on whatever element is
    // under the cursor. Without this, the checkbox / chevron / row body
    // would fire its own phx-click handler on top of (or instead of) our
    // drop. Applies to both commit and snap-back paths.
    this.suppressNextClick()

    const plan = this.dropPlan
    if (!plan || !this.sourceLi) {
      this.cleanup()
      return
    }

    const taskId = parseInt(this.sourceLi.dataset.taskId, 10)
    const params = {
      task_id: taskId,
      parent_id: plan.parentId,
      position: plan.position,
      reorder: !!plan.reorder,
    }

    // Temporary drop tracing, gated behind the idclip easter egg so it's silent
    // in normal use. Prints what the drop computed vs. what we push to the server.
    if (document.documentElement.classList.contains("debug-task-ids")) {
      const liId = (el) => {
        const li = el && el.closest && el.closest("li[data-task-id]")
        return li ? li.dataset.taskId : null
      }
      console.log("[idclip] drop", {
        drag: taskId,
        source_parent: liId(this.sourceLi.parentElement),
        anchor: this.anchorLi ? this.anchorLi.dataset.taskId : null,
        placeholder_parent: this.placeholderEl ? liId(this.placeholderEl.parentElement) : null,
        tail_parent: this.activeTail ? liId(this.activeTail.parentElement) : null,
        "->push parent_id": plan.parentId,
        "->push position": plan.position,
        "->push reorder": !!plan.reorder,
      })
    }

    // Optimistic UI (.03.03.08): move the row to the drop indicator now and pink
    // the affected group; the server's authoritative re-render clears the hue
    // (the class is client-added, so morphdom strips it). Revert on a failed
    // write — the server also re-renders the unchanged tree.
    const origParent = this.sourceLi.parentElement
    const origNext = this.sourceLi.nextSibling
    const sourceParentLi = origParent && origParent.closest("li[data-task-id]")
    const dest = this.optimisticDest(plan)
    // Predict the completion flip from the ORIGINAL tree, before we move the row
    // (UX_GUARDRAILS 6.5). null = no predicted flip → push as usual; otherwise
    // hold the optimistic placement and open the instant confirm below.
    let prediction = null
    if (dest && dest.container) {
      const destParentLiPred = dest.container.closest("li[data-task-id]")
      prediction = predictMoveFlip(this.sourceLi, sourceParentLi, destParentLiPred)
    }
    if (dest && dest.container) {
      const destParentLi = dest.container.closest("li[data-task-id]")
      dest.container.insertBefore(this.sourceLi, dest.before)
      // Extra rows whose DB row certainly gets written. A same-parent reorder
      // affects the parent only when it flips its sort_mode to manual — an
      // already-manual parent doesn't change. A cross-parent move pinks BOTH
      // immediate parents (one loses a child, one gains — their % moves in
      // almost every case, and the parent rows stay visible even when a
      // branch's children are collapsed). Ancestor chains above stay quiet:
      // those updates are value-dependent.
      const extra = []
      if (sourceParentLi === destParentLi) {
        const r = destParentLi && destParentLi.firstElementChild
        if (r && dest.container.dataset.sortMode !== "manual") extra.push(r)
      } else {
        // Both parents' % is in flight on a cross-parent move — pink them
        // AND go indeterminate (.03.07.23).
        if (sourceParentLi) extra.push(sourceParentLi.firstElementChild)
        if (destParentLi) extra.push(destParentLi.firstElementChild)
        extra.forEach((r) => r && r.classList.add("is-recomputing"))
      }
      this.markSaving(dest.container, extra)
    }

    const fabricatedUl = this._fabricatedUl
    this._fabricatedUl = null
    const movedLi = this.sourceLi
    if (!prediction) {
      // No predicted flip: push exactly as before. The server commits; if it
      // disagrees and detects a flip the client missed, its committed:false
      // path renders #completion-confirm (the backstop) — handled below.
      this.pushEvent("move_task", params, (reply) => {
        const failed = !reply || reply.ok === false
        if (failed) {
          // A failed write snaps the row back — the server re-renders the
          // unchanged tree.
          revertPendingMove()
          this.clearSaving()
        } else if (reply.committed !== false) {
          // Committed: the placement is truth now; release the hold. Clear the
          // hue explicitly — don't rely on morphdom stripping it, which is
          // unreliable once we've moved the DOM ourselves.
          window.DoitPendingMove = null
          this.clearSaving()
        } else {
          // The server caught a flip we didn't predict — its #completion-confirm
          // backstop is now up. The hold stays (§8.20) until
          // "confirm-cancelled" / "confirm-resolved", and the rows carry the
          // SERVER's maybe-write hue: stop tracking without stripping, or the
          // gesture timer unpinks the open modal.
          this.releaseSaving()
        }
      })
    } else {
      // Predicted flip: keep the optimistic placement and open the instant
      // client confirm NOW (no round trip). Don't push yet — Proceed re-sends
      // with confirmed:true; Cancel reverts. The saving hue stays up while the
      // modal decides, so release the gesture timer (don't let it unpink the
      // open modal) without stripping the classes.
      this.releaseSaving()
    }
    this.cleanup()
    // The hold is registered BEFORE the reply can race it: any patch landing
    // first (the confirm's pending-hue render) re-creates the row under its
    // server-side parent, and onPatchEnd needs the handle to fix that
    // (incl. removing the re-created clone — see applyPendingMove). Captured
    // after cleanup so the drop placeholder doesn't pollute the held position.
    // moveParams rides along so a predicted-flip Proceed can re-send the same
    // move with confirmed:true.
    window.DoitPendingMove = {
      li: movedLi,
      parent: origParent,
      next: origNext,
      fabricatedUl,
      destContainer: movedLi.parentElement,
      destNext: movedLi.nextElementSibling,
      moveParams: params,
    }
    if (prediction) {
      // Fill + show the modal after DoitPendingMove is set (the Proceed handler
      // reads moveParams off it). If the modal is missing, fall back to the
      // server path so the move still happens (just with the old late confirm).
      if (!openMoveFlipConfirm(prediction)) {
        this.pushEvent("move_task", params, (reply) => {
          const failed = !reply || reply.ok === false
          if (failed) {
            revertPendingMove()
          } else if (reply.committed !== false) {
            window.DoitPendingMove = null
          }
          document.querySelectorAll(".is-saving, .is-recomputing").forEach((el) => {
            el.classList.remove("is-saving", "is-recomputing")
          })
        })
      }
    }
  },

  // Where the drop's visual indicator says the row should land — reuse the
  // placeholder / tail / root-zone / center target rather than re-deriving it.
  optimisticDest(plan) {
    if (this.placeholderEl && this.placeholderEl.parentElement) {
      return {container: this.placeholderEl.parentElement, before: this.placeholderEl}
    }
    if (this.activeTail && this.activeTail.parentElement) {
      return {container: this.activeTail.parentElement, before: this.activeTail}
    }
    if (plan.parentId === null) {
      const rootUl = document.getElementById("task-tree")
      if (rootUl) {
        const before = plan.position === 0 ? rootUl.querySelector(":scope > li[data-task-id]") : null
        return {container: rootUl, before}
      }
    }
    // Center (reparent as first child). If the anchor is a leaf with no child
    // list yet, fabricate one with the right id so the reparent is optimistic
    // too — morphdom reconciles it against the server's real <ul> on re-render.
    if (this.anchorLi && !plan.reorder) {
      let ul = this.anchorLi.querySelector(":scope > ul[id^='children-']")
      if (!ul) {
        ul = document.createElement("ul")
        ul.id = "children-" + this.anchorLi.dataset.taskId
        ul.className = "pl-1.5 sm:pl-6 space-y-1"
        this.anchorLi.appendChild(ul)
        // Remember it so a non-committed move can remove the empty shell.
        this._fabricatedUl = ul
      }
      return {container: ul, before: ul.querySelector(":scope > li[data-task-id]")}
    }
    return null
  },

  // Pink the affected rows: the moved/reordered children of `container`, plus
  // any `extraRows` (parent and/or ancestor rows whose value changes). We don't
  // pink the container <ul> itself — its tint would bleed through the child area.
  markSaving(container, extraRows) {
    this.clearSaving()
    this._saving = []
    const add = (el) => {
      if (el) {
        el.classList.add("is-saving")
        this._saving.push(el)
      }
    }
    if (container) {
      container
        .querySelectorAll(":scope > li[data-task-id] > div:first-child")
        .forEach(add)
    }
    ;(extraRows || []).forEach(add)
    // Safety net: never let the hue linger if the reply never comes.
    this._savingTimer = setTimeout(() => this.clearSaving(), 1500)
  },
  // Push the row of `li` and each of its ancestor task rows onto `acc` — the
  // chain whose progress recomputes on a cross-parent move. Stops at the root
  // task (top-level tasks have no rendered parent row).
  collectAncestorRows(li, acc) {
    let cur = li
    while (cur && cur.matches && cur.matches("li[data-task-id]")) {
      if (cur.firstElementChild) acc.push(cur.firstElementChild)
      cur = cur.parentElement && cur.parentElement.closest("li[data-task-id]")
    }
  },
  clearSaving() {
    if (this._savingTimer) {
      clearTimeout(this._savingTimer)
      this._savingTimer = null
    }
    if (this._saving) {
      this._saving.forEach((el) => el.classList.remove("is-saving", "is-recomputing"))
    }
    this._saving = null
  },
  // Stop tracking without stripping classes — the server's pending hue owns
  // the rows once a confirm modal is up.
  releaseSaving() {
    if (this._savingTimer) {
      clearTimeout(this._savingTimer)
      this._savingTimer = null
    }
    this._saving = null
  },

  abort() {
    this.cleanup()
  },

  // Touch only: the user swiped the handle instead of holding to drag. Nudge
  // them with a one-line flash explaining the gesture — capped per browser
  // session (not lifetime) so an occasional / PC-primary user gets re-taught
  // each time they return to mobile, without nagging within a session.
  maybeDragHint() {
    const KEY = "doit:drag-hint-count"
    const shown = parseInt(sessionStorage.getItem(KEY) || "0", 10)
    if (shown >= 3) return
    sessionStorage.setItem(KEY, String(shown + 1))
    this.showDragHintToast()
  },

  // A self-dismissing toast that embeds THIS row's actual handle (grip dots +
  // its type icon) inline, so "tap and hold the handle" is unambiguous — the
  // user sees exactly what to grab. Pure client-side; the handle markup is
  // ours (no user input), so cloning innerHTML is safe.
  showDragHintToast() {
    const prev = document.getElementById("drag-hint-toast")
    if (prev) prev.remove()

    const toast = document.createElement("div")
    toast.id = "drag-hint-toast"
    toast.setAttribute("role", "status")
    toast.className =
      "fixed bottom-4 left-1/2 -translate-x-1/2 z-50 max-w-xs px-3 py-2 rounded-lg " +
      "border border-zinc-200 dark:border-zinc-700 bg-white dark:bg-zinc-900 " +
      "text-sm text-zinc-700 dark:text-zinc-200 shadow-lg"
    toast.innerHTML =
      `Tap and hold a task's handle (<span class="inline-flex items-center align-middle">` +
      `${this.el.innerHTML}</span>) to drag it to a different position.`

    document.body.appendChild(toast)
    setTimeout(() => toast.remove(), 5000)
  },

  suppressNextClick() {
    const swallow = (e) => {
      e.preventDefault()
      e.stopPropagation()
      e.stopImmediatePropagation()
      document.removeEventListener("click", swallow, true)
      clearTimeout(timeout)
    }
    document.addEventListener("click", swallow, true)
    // Synthetic clicks after pointerup fire essentially synchronously;
    // 50ms is comfortably above that and well below the server-roundtrip
    // + modal-render + user-react path. The old 300ms fallback could
    // swallow the Cancel click on a freshly-opened confirm modal.
    const timeout = setTimeout(() => {
      document.removeEventListener("click", swallow, true)
    }, 50)
  },

  cleanup() {
    this.clearLongPressTimer()
    this.clearPrimingCue()

    if (this.onMove) document.removeEventListener("pointermove", this.onMove)
    if (this.onUp) document.removeEventListener("pointerup", this.onUp)
    if (this.onCancel) document.removeEventListener("pointercancel", this.onCancel)
    if (this.onKeyDown) document.removeEventListener("keydown", this.onKeyDown)
    this.onMove = this.onUp = this.onCancel = this.onKeyDown = null

    this.clearAnchorHighlight()
    this.unmountRootZones()
    if (this.sourceLi) this.sourceLi.classList.remove("dragging-source")
    this.sourceLi = null

    if (this.edgeRAF) { cancelAnimationFrame(this.edgeRAF); this.edgeRAF = null }
    this.scrollEl = null
    this.lastClientX = this.lastClientY = null

    document.body.style.userSelect = ""
    document.body.style.cursor = ""

    this.armed = false
    this.dragging = false
    this.dropPlan = null
    this.longPressFired = false
    this.activePointerId = undefined
    this.pointerType = undefined
  },

  clearAnchorHighlight() {
    if (this.anchorLi) this.anchorLi.classList.remove("drop-target")
    this.anchorLi = null
    this.clearForbidden()
    this.clearPlaceholder()
    this.clearZoneActive()
    this.clearTailActive()
  },

  // ---- Tree helpers ------------------------------------------------------
  isDescendantOfSource(li) {
    return this.sourceLi && this.sourceLi.contains(li)
  },

  // Vertical band of a row under clientY: "above" | "center" | "below" (item
  // 21). Edge bands are thin strips at the row's top/bottom edges; everything
  // between is center/reparent — so most of the row (the progress underbar
  // included) is a stable highlight, with no special-casing for the bar. An
  // expanded branch has NO "below" band — its tail zone handles "last child".
  bandFor(li, clientY) {
    const row = li.firstElementChild || li
    const rect = row.getBoundingClientRect()
    const EDGE = 9 // px strip at each edge

    if (clientY < rect.top + EDGE) return "above"
    if (!this.hasVisibleChildren(li) && clientY >= rect.bottom - EDGE) return "below"
    return "center"
  },

  // True when the row's children are rendered and not collapsed — an expanded
  // branch. Such rows get no "below" band (their tail zone handles last-child).
  hasVisibleChildren(li) {
    const ul = li.querySelector(":scope > ul[id^='children-']")
    return !!ul && !ul.classList.contains("collapsed-peek")
  },

  // The anchor's parent task id, read from its drag handle's data-parent-id.
  // Root rows omit the attribute (nil → no attr in HEEx) → null.
  anchorParentId(li) {
    const handle = li.querySelector(":scope > div [data-parent-id]")
    const raw = handle && handle.dataset.parentId
    return raw ? parseInt(raw, 10) : null
  },

  // 0-based insertion index for a sibling reorder, in the server's terms:
  // an index into the destination sibling list EXCLUDING the source.
  // `band` is "above" or "below" the anchor.
  siblingPosition(anchorLi, band) {
    const sibs = this.siblingLis(anchorLi)
    const anchorIdx = sibs.indexOf(anchorLi)
    const sourceIdx = sibs.indexOf(this.sourceLi)
    // When the source shares this list and sits before the anchor, removing
    // it shifts the anchor's index down by one.
    let base = anchorIdx
    if (sourceIdx !== -1 && sourceIdx < anchorIdx) base -= 1
    return band === "above" ? base : base + 1
  },

  // Task <li> siblings of the given li (direct children of its <ul> that
  // carry data-task-id), in DOM order. Excludes form rows and the like.
  siblingLis(li) {
    const ul = li.parentElement
    if (!ul) return [li]
    return Array.from(ul.children).filter(
      (c) => c.matches && c.matches("li[data-task-id]"),
    )
  },

  // Insert a thin drop-indicator bar above/below the anchor row. One element
  // reused across moves; clearPlaceholder() detaches it (cleanup runs before
  // the server's re-render arrives, so morphdom never sees it).
  showPlaceholder(anchorLi, band) {
    if (!this.placeholderEl) {
      this.placeholderEl = document.createElement("li")
      this.placeholderEl.className = "drop-placeholder"
      this.placeholderEl.setAttribute("aria-hidden", "true")
    }
    const ul = anchorLi.parentElement
    if (!ul) return
    if (band === "above") ul.insertBefore(this.placeholderEl, anchorLi)
    else ul.insertBefore(this.placeholderEl, anchorLi.nextSibling)
  },

  clearPlaceholder() {
    if (this.placeholderEl && this.placeholderEl.parentElement) {
      this.placeholderEl.parentElement.removeChild(this.placeholderEl)
    }
  },

  // ---- Tail zones (item 21: "last child of this branch") -----------------
  // 0-based position that appends the source as the branch's last child:
  // the count of its existing task children, less the source if already among
  // them (the server's sibling list excludes the moved task).
  lastChildPosition(branchLi) {
    const ul = branchLi.querySelector(":scope > ul[id^='children-']")
    const kids = ul
      ? Array.from(ul.children).filter((c) => c.matches && c.matches("li[data-task-id]"))
      : []
    let pos = kids.length
    if (this.sourceLi && kids.includes(this.sourceLi)) pos -= 1
    return pos
  },

  setTailActive(tailLi) {
    this.clearTailActive()
    tailLi.classList.add("is-over")
    this.activeTail = tailLi
  },

  clearTailActive() {
    if (this.activeTail) this.activeTail.classList.remove("is-over")
    this.activeTail = null
  },

  // ---- Root overlay zones (item 17) --------------------------------------
  // Two slim drop targets bracketing the root list, present only during a
  // drag. The first li[data-task-id] in the document is the first root, so
  // its <ul> is the root list. Idempotent against the touch begin-drag race.
  mountRootZones() {
    if (this.topZone) return
    const firstRoot = document.querySelector("li[data-task-id]")
    const rootUl = firstRoot && firstRoot.parentElement
    if (!rootUl) return
    this.topZone = this.makeRootZone("top")
    this.bottomZone = this.makeRootZone("bottom")
    rootUl.insertBefore(this.topZone, rootUl.firstChild)
    rootUl.appendChild(this.bottomZone)
  },

  makeRootZone(which) {
    const el = document.createElement("li")
    el.className = "drop-root-zone"
    el.dataset.zone = which
    el.setAttribute("aria-hidden", "true")
    return el
  },

  unmountRootZones() {
    if (this.topZone && this.topZone.parentElement) this.topZone.remove()
    if (this.bottomZone && this.bottomZone.parentElement) this.bottomZone.remove()
    this.topZone = this.bottomZone = null
  },

  rootZoneAt(x, y) {
    if (this.topZone && this.pointIn(this.topZone, x, y)) return this.topZone
    if (this.bottomZone && this.pointIn(this.bottomZone, x, y)) return this.bottomZone
    return null
  },

  pointIn(el, x, y) {
    const r = el.getBoundingClientRect()
    return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom
  },

  setZoneActive(zone) {
    this.clearZoneActive()
    zone.classList.add("is-over")
    this.activeZone = zone
  },

  clearZoneActive() {
    if (this.activeZone) this.activeZone.classList.remove("is-over")
    this.activeZone = null
  },
}

// Per-task collapse/expand toggle for the task tree on /initiatives/:id.
// Persists state in localStorage keyed by (initiative_id, task_id).
// Toggling never affects roll-up — it only hides the children <ul>.
// Positions a native [popover] panel next to its popovertarget trigger,
// clamped inside the viewport (the top layer ignores ancestor overflow, so
// without this it would center like a dialog).
Hooks.Popover = {
  mounted() {
    this._onToggle = (e) => {
      if (e.newState !== "open") return
      // Reset any inline confirm step (e.g. the collaborators menu) so a
      // re-open always shows the default panel, never a stale confirm.
      this.el.querySelectorAll("[data-confirm-step]").forEach((el) => el.classList.add("hidden"))
      this.el.querySelectorAll("[data-menu-step]").forEach((el) => el.classList.remove("hidden"))
      const btn = document.querySelector(`[popovertarget='${this.el.id}']`)
      if (!btn) return
      const r = btn.getBoundingClientRect()
      const width = Math.min(this.el.offsetWidth || 256, window.innerWidth - 16)
      const left = Math.min(Math.max(8, r.left), window.innerWidth - width - 8)
      let top = r.bottom + 6
      const height = this.el.offsetHeight
      if (top + height > window.innerHeight - 8) top = Math.max(8, r.top - height - 6)
      Object.assign(this.el.style, {
        position: "fixed",
        left: left + "px",
        top: top + "px",
        margin: "0",
      })
    }
    this.el.addEventListener("toggle", this._onToggle)
  },
  destroyed() {
    this.el.removeEventListener("toggle", this._onToggle)
  },
}

Hooks.CollapseToggle = {
  mounted() { ensureStorageVersion("phx:collapse", 1, { grandfather: true }); this.bind(); this.apply() },
  updated() { this.apply() },
  storageKey() { return `phx:collapse:${this.el.dataset.initiativeId}:${this.el.dataset.taskId}` },
  childrenEl() { return document.getElementById(`children-${this.el.dataset.taskId}`) },
  apply() {
    const ce = this.childrenEl()
    if (!ce) return
    const collapsed = localStorage.getItem(this.storageKey()) === "1"
    ce.classList.toggle("collapsed-peek", collapsed)
    this.el.setAttribute("aria-expanded", String(!collapsed))
  },
  bind() {
    this.el.addEventListener("click", (e) => {
      e.stopPropagation()
      const ce = this.childrenEl()
      if (!ce) return
      const collapsed = !ce.classList.contains("collapsed-peek")
      ce.classList.toggle("collapsed-peek", collapsed)
      this.el.setAttribute("aria-expanded", String(!collapsed))
      localStorage.setItem(this.storageKey(), collapsed ? "1" : "0")
    })
  },
}

// Selection-presence badges (m02.04 §1.12). The server pushes the full
// "who has what selected" list (other members only); this hook stores it
// window-level and paints [data-presence-slot] spans. Like collapse state,
// the painted DOM is client-owned — the patch guard below re-applies it
// after any morphdom pass wipes a slot.
Hooks.PresenceBadges = {
  mounted() {
    this.handleEvent("presence-selections", ({ selections, online }) => {
      DoitState.presence.selections = selections
      DoitState.presence.online = online || []
      applyPresenceBadges()
    })
  },
  destroyed() {
    DoitState.presence.selections = []
    DoitState.presence.online = []
  },
}

// `window.DoitPresence` is now backed by DoitState.presence so presence has a
// single source of truth: applyPresenceBadges (reads .selections/.online), the
// hook's handleEvent, and the preserve-path KeepRegistry.presence applier all
// read the same store and stay consistent.
const DoitPresence = {
  get selections() { return DoitState.presence.selections },
  set selections(v) { DoitState.presence.selections = v },
  get online() { return DoitState.presence.online },
  set online(v) { DoitState.presence.online = v },
}
window.DoitPresence = DoitPresence

function applyPresenceBadges() {
  const sels = (window.DoitPresence && window.DoitPresence.selections) || []
  const byTask = new Map()
  sels.forEach((s) => {
    if (!s.task_id) return
    const key = String(s.task_id)
    const arr = byTask.get(key) || []
    arr.push(s)
    byTask.set(key, arr)
  })
  document.querySelectorAll("[data-presence-slot]").forEach((slot) => {
    const list = byTask.get(slot.dataset.presenceSlot) || []
    // Converge instead of loop: only rewrite when the badge set changed
    // (the patch guard runs this after every DOM mutation, ours included).
    const sig = list.map((s) => `${s.user_id}:${s.initials}:${s.bg}:${s.fg}`).join("|")
    if (slot.dataset.sig === sig) return
    slot.dataset.sig = sig
    slot.replaceChildren(
      ...list.map((s) => {
        const b = document.createElement("span")
        b.className =
          "avatar-emboss inline-flex flex-none items-center justify-center w-4 h-4 rounded-full text-[8px] font-semibold select-none"
        b.style.backgroundImage = s.bg
        b.style.color = s.fg
        b.textContent = s.initials
        b.title = `${s.name} has this task selected`
        return b
      })
    )
  })

  // Assignee-chip online dots from the same push (classList.toggle is a
  // no-op write when the state matches, so the patch guard converges).
  const online = new Set(((window.DoitPresence && window.DoitPresence.online) || []).map(String))
  document.querySelectorAll("[data-pill-avatar]").forEach((el) => {
    el.classList.toggle("chip-online", !!el.dataset.assigneeId && online.has(el.dataset.assigneeId))
  })
}

// Sizes the whole task tree to one width so every row — roots included —
// renders uniformly and the tree scrolls horizontally only when depth genuinely
// needs it (ProductSpec § Task Tree Display). The width is driven by the deepest
// *visible* row: min-width = (that row's indentation) + FLOOR, applied to the
// root <ul>. Rows inside a collapsed branch (ul.collapsed-peek) are excluded, so
// collapsing a deep branch shrinks the tree. Indentation is measured (not
// computed from depth) so it's robust to the responsive nest-padding.
const TREE_WIDTH_FLOOR_PX = 240
Hooks.TreeWidth = {
  mounted() {
    this.schedule = () => {
      if (this.raf) return
      this.raf = requestAnimationFrame(() => { this.raf = null; this.recompute() })
    }
    this.onResize = () => this.schedule()
    window.addEventListener("resize", this.onResize)
    // Collapse/expand toggles a class with no LiveView render; tree edits change
    // the DOM. One observer (class + childList) catches both. style writes on
    // the <ul> aren't in the filter, so setting min-width can't self-trigger.
    this.observer = new MutationObserver(() => this.schedule())
    this.observer.observe(this.el, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["class"],
    })
    this.recompute()
    // %-notation read path: render tokens -> links on mount and after every tree
    // patch. updated() fires whenever the server patches anything in this subtree
    // (a title/description edit, a re-number) — morphdom first resets the changed
    // element to its raw token text, then this re-renders the links (and refreshes
    // labels on every other row so numbers stay live). Driven off the SAME
    // updated() TreeWidth already relies on for content patches — NOT the
    // MutationObserver above, which would re-trigger on our own DOM writes.
    // Renders DOCUMENT-WIDE (Wave 3), not just this tree, so a re-number also
    // refreshes comment + chat ref labels while they're shown.
    renderAllRefs(document)
  },
  updated() { this.schedule(); renderAllRefs(document) },
  destroyed() {
    window.removeEventListener("resize", this.onResize)
    if (this.observer) this.observer.disconnect()
    if (this.raf) cancelAnimationFrame(this.raf)
  },
  recompute() {
    const ulLeft = this.el.getBoundingClientRect().left
    let maxLeft = 0
    this.el.querySelectorAll("[data-task-row]").forEach((row) => {
      if (row.closest("ul.collapsed-peek")) return // hidden by a collapsed ancestor
      const left = row.getBoundingClientRect().left - ulLeft // scroll-invariant indent
      if (left > maxLeft) maxLeft = left
    })
    const next = Math.ceil(maxLeft + TREE_WIDTH_FLOOR_PX) + "px"
    if (this.el.style.minWidth !== next) this.el.style.minWidth = next
  },
}

// Tree scroll-fade signifier (m02.07 item 1.3). Lives on the tree's scroll box
// (#tree-scroll) but flips data-scrolled / data-at-end on its parent FRAME, so
// the fade overlays (sticky descendants of the frame) read them as
// group-data-* variants (CSS owns show/hide — no animation-timeline, for
// cross-browser safety). The overlays are pointer-events-none, so this is
// purely decorative state. They sit INSIDE the scroll box so the scrollport
// (excludes both scrollbars) bounds them — no scrollbar measurement.
//
// - data-scrolled: present once scrolled down from the very top (top fade on).
// - data-at-end:   present while the box is at (or can't) scroll to the bottom
//                  (bottom fade off). A 1px slack absorbs sub-pixel rounding.
Hooks.TreeScrollFade = {
  mounted() {
    this.frame = this.el.parentElement
    this.schedule = () => {
      if (this.raf) return
      this.raf = requestAnimationFrame(() => { this.raf = null; this.recompute() })
    }
    this.el.addEventListener("scroll", this.schedule, { passive: true })
    this.onResize = () => this.schedule()
    window.addEventListener("resize", this.onResize)
    // Tree edits / collapse change the content height; recompute the at-end
    // edge so the bottom fade tracks it (mirrors TreeWidth's observer).
    this.observer = new MutationObserver(() => this.schedule())
    this.observer.observe(this.el, { subtree: true, childList: true, attributes: true, attributeFilter: ["class"] })
    this.recompute()
  },
  updated() { this.schedule() },
  destroyed() {
    this.el.removeEventListener("scroll", this.schedule)
    window.removeEventListener("resize", this.onResize)
    if (this.observer) this.observer.disconnect()
    if (this.raf) cancelAnimationFrame(this.raf)
  },
  recompute() {
    if (!this.frame) return
    const el = this.el
    const scrolled = el.scrollTop > 0
    const atEnd = el.scrollTop + el.clientHeight >= el.scrollHeight - 1
    this.frame.toggleAttribute("data-scrolled", scrolled)
    this.frame.toggleAttribute("data-at-end", atEnd)
    // No scrollbar measurement: the fades are sticky overlays INSIDE the scroll
    // box, so the scrollport (which excludes both scrollbars by definition)
    // bounds them on every platform — the bottom fade sits above the horizontal
    // scrollbar, and the scrollport-width fades stop short of the vertical one.
  },
}

// Initiatives-index sort control. The preference is server-persisted (m02.04
// §2.6): mode + per-mode reverse on the user's prefs record, manual drag
// order on their membership rows. The server renders the saved state into
// the (phx-update="ignore") controls and the per-mode reverse memory into
// data-reverse-by-mode; this hook owns the controls from there and pushes
// apply_sort on change — no localStorage, the preference follows the account.
function readReverseByMode() {
  const form = document.getElementById("initiative-sort")
  try {
    return JSON.parse((form && form.dataset.reverseByMode) || "{}") || {}
  } catch {
    return {}
  }
}
Hooks.InitiativeSort = {
  mounted() {
    this.sel = this.el.querySelector("select[name=mode]")
    this.rev = this.el.querySelector("input[name=reverse]")
    this.reverseByMode = readReverseByMode()

    // Switching modes reflects that mode's remembered reverse.
    this.sel.addEventListener("change", () => {
      this.rev.checked = !!this.reverseByMode[this.sel.value]
      this.push()
    })
    // Toggling reverse updates only the current mode's setting.
    this.rev.addEventListener("change", () => {
      this.reverseByMode[this.sel.value] = this.rev.checked
      this.persist()
      this.push()
    })
  },
  // Keep the form's data attribute in step so the drag hook (a separate
  // instance) reads fresh per-mode reverse state.
  persist() {
    this.el.dataset.reverseByMode = JSON.stringify(this.reverseByMode)
  },
  push() {
    // The cards carry their sort keys as data attributes, so explicit modes
    // reorder client-side at the change (UX_GUARDRAILS 6.5); the server
    // re-stream below confirms the same order. "Recent" (the default mode)
    // is server-derived (owner-first, recently-updated) and stays with it.
    // No order in the payload — only a drag pushes one.
    this.clientSort()
    // "Recent" (empty mode) — and Reverse while in Recent — can't be reordered
    // client-side, so there's nothing to reflect at the gesture. Show an
    // in-flight saving hue on the cards AND spin the select's adjacent busy slot
    // so the re-sort isn't silent (UX_GUARDRAILS §6.7); the server re-stream
    // strips the hue (1.5s net) and the apply_sort reply clears the control
    // (the select sits in a phx-update="ignore" form, so morphdom never does —
    // setControlBusy's ~8s timer is the final safety net).
    let clearBusy = null
    if (!this.sel.value) {
      const wrap = document.getElementById("initiatives")
      if (wrap) markSaving([...wrap.querySelectorAll(":scope > [data-initiative-id]")])
      clearBusy = setControlBusy(this.sel)
    }
    this.pushEvent(
      "apply_sort",
      {
        mode: this.sel.value || "",
        reverse: !!this.reverseByMode[this.sel.value],
      },
      () => { if (clearBusy) clearBusy() }
    )
  },
  clientSort() {
    const wrap = document.getElementById("initiatives")
    const mode = this.sel.value
    if (!wrap || !mode) return
    const cards = [...wrap.querySelectorAll(":scope > [data-initiative-id]")]
    let sorted
    if (mode === "manual") {
      // Saved order rides the cards as data-my-order (kept fresh by the
      // server after every drag persist).
      const pos = (el) => (el.dataset.myOrder === undefined ? Infinity : parseInt(el.dataset.myOrder, 10))
      sorted = cards.slice().sort((a, b) => pos(a) - pos(b))
    } else {
      const key = (el) =>
        mode === "progress"
          ? parseFloat(el.dataset.progress || "0")
          : mode === "name"
            ? (el.dataset.name || "").toLowerCase()
            : el.dataset[mode] || ""
      sorted = cards.slice().sort((a, b) => (key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0))
    }
    if (this.reverseByMode[mode]) sorted.reverse()
    sorted.forEach((el) => wrap.appendChild(el))
  },
}

// Server-driven close for client-toggled <details> (e.g. the index's New
// Initiative form after a successful create). reset() restores the inputs to
// the freshly re-rendered empty defaults.
window.addEventListener("phx:close-details", (e) => {
  const id = (e.detail && e.detail.id) || ""
  const d = document.getElementById(id)
  if (!d) return
  d.open = false
  // Evict the client-owned open-state so the preserve path ("open" applier) can't
  // re-open it on the re-render patch that rides this same response (the
  // add-member / create form stayed open until now).
  delete DoitState.detailsOpen[id]
  const form = d.querySelector("form")
  if (form) form.reset()
})

// ---- Drop-time optimism for the Initiatives card reorder (WL3.5 Fix A) -----
//
// A drag-reorder of the workspace Initiative cards (#initiatives) used to wait
// on the server re-stream — no drop-time feedback (§6.2 violation). We now apply
// the new order to the DOM AT DROP, snapshot the prior order, and hold it on the
// preserve path until the apply_sort reply settles. This mirrors the structural
// applyPendingMove hold: it's a child reorder, so it gets no per-element
// data-keep kind — applyPendingInitiativeOrder re-asserts it from onPatchEnd
// (covering any unrelated mid-flight patch), and the reply releases it (ok) or
// reverts to the prior snapshot (failure — MUST NOT LIE). A dropped reply
// self-heals on the 8s safety timer by releasing (the server stays
// authoritative; the next re-stream reconciles the order honestly).

// Re-sequence #initiatives' card children to `order` (an id list) by appending
// in order — idempotent, so re-running from onPatchEnd converges.
function reorderInitiativeCards(wrap, order) {
  const byId = new Map(
    [...wrap.querySelectorAll(":scope > [data-initiative-id]")].map((c) => [
      c.dataset.initiativeId,
      c,
    ]),
  )
  order.forEach((id) => {
    const card = byId.get(String(id))
    if (card) wrap.appendChild(card)
  })
}

// Re-assert the held optimistic order after every patch (onPatchEnd). While a
// hold stands, the cards stay in the dropped order even if an unrelated patch
// re-touches the stream container.
function applyPendingInitiativeOrder() {
  const p = DoitState.pending.initiativeOrder
  if (!p) return
  const wrap = document.getElementById(p.wrapId)
  if (wrap) reorderInitiativeCards(wrap, p.order)
}

// Settle the hold on the apply_sort reply. ok → release (the server persisted
// the order and re-streamed it; it now stands). failure → revert to the prior
// snapshot + bonk (the order didn't take — don't leave a phantom reorder).
function settlePendingInitiativeOrder(reply) {
  const p = DoitState.pending.initiativeOrder
  if (!p) return
  if (p.timer) clearTimeout(p.timer)
  if (reply && reply.ok === false) {
    revertPendingInitiativeOrder()
    if (window.DoitBonk) window.DoitBonk()
  } else {
    DoitState.pending.initiativeOrder = null
  }
}

function revertPendingInitiativeOrder() {
  const p = DoitState.pending.initiativeOrder
  DoitState.pending.initiativeOrder = null
  if (!p) return
  if (p.timer) clearTimeout(p.timer)
  const wrap = document.getElementById(p.wrapId)
  if (wrap) reorderInitiativeCards(wrap, p.prior)
}

// Drag-to-reorder the Initiatives index (.06.3). The grove icon is the handle;
// dropping inserts the card before/after another (no reparent / center drop).
// The new order is applied at drop (WL3.5 Fix A) and pushed as apply_sort (mode
// "manual"); the server persists it onto the membership rows (m02.04 §2.6).
// Reuses the pointer-event pattern from DragReorder, in a simpler reorder-only
// form.
const INIT_DRAG_THRESHOLD_PX = 4
const INIT_DRAG_LONG_PRESS_MS = 400
const INIT_DRAG_TOUCH_TOLERANCE_PX = 8
Hooks.InitiativeDrag = {
  mounted() {
    this.onDown = (e) => this.start(e)
    // The handle sits inside the card's <a>; on touch, a long-press would
    // otherwise fire the iOS link callout / context menu and cancel the drag.
    this.onContext = (e) => e.preventDefault()
    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("contextmenu", this.onContext)
  },
  destroyed() {
    this.cleanup()
    if (this.onDown) this.el.removeEventListener("pointerdown", this.onDown)
    if (this.onContext) this.el.removeEventListener("contextmenu", this.onContext)
  },
  start(e) {
    if (e.button !== undefined && e.button !== 0) return
    if (this.armed || this.dragging) return
    e.preventDefault() // don't navigate the card link
    e.stopPropagation()
    this.startY = e.clientY
    this.pointerType = e.pointerType || "mouse"
    this.pid = e.pointerId
    this.armed = true
    this.dragging = false
    this.card = this.el.closest("[data-initiative-id]")
    this.container = this.card && this.card.parentElement
    this.longFired = this.pointerType !== "touch"

    this.onMove = (ev) => this.move(ev)
    this.onUp = (ev) => this.up(ev)
    this.onCancel = () => this.abort()
    document.addEventListener("pointermove", this.onMove)
    document.addEventListener("pointerup", this.onUp)
    document.addEventListener("pointercancel", this.onCancel)

    if (this.pointerType === "touch") {
      this.timer = setTimeout(() => {
        this.timer = null
        if (this.armed && !this.dragging) {
          this.longFired = true
          this.begin()
        }
      }, INIT_DRAG_LONG_PRESS_MS)
    }
  },
  begin() {
    this.dragging = true
    if (this.card) this.card.style.opacity = "0.5"
    document.body.style.userSelect = "none"
    document.body.style.cursor = "grabbing"
  },
  move(e) {
    if (!this.armed) return
    if (this.pid !== undefined && e.pointerId !== this.pid) return

    if (!this.dragging) {
      if (this.pointerType === "touch" && !this.longFired) {
        if (Math.abs(e.clientY - this.startY) >= INIT_DRAG_TOUCH_TOLERANCE_PX) this.abort()
        return
      }
      if (Math.abs(e.clientY - this.startY) < INIT_DRAG_THRESHOLD_PX) return
      this.begin()
    }

    this.clearPlaceholder()
    const under = document.elementFromPoint(e.clientX, e.clientY)
    const overCard = under && under.closest("[data-initiative-id]")
    if (!overCard || overCard === this.card || overCard.parentElement !== this.container) {
      this.target = null
      return
    }
    const rect = overCard.getBoundingClientRect()
    this.after = e.clientY > rect.top + rect.height / 2
    this.target = overCard
    this.showPlaceholder(overCard, this.after)
  },
  showPlaceholder(card, after) {
    if (!this.ph) {
      this.ph = document.createElement("div")
      this.ph.className = "init-drop-placeholder"
      this.ph.setAttribute("aria-hidden", "true")
    }
    if (after) card.after(this.ph)
    else card.before(this.ph)
  },
  clearPlaceholder() {
    if (this.ph && this.ph.parentElement) this.ph.parentElement.removeChild(this.ph)
  },
  up(e) {
    if (!this.armed) return
    if (this.pid !== undefined && e.pointerId !== this.pid) return
    if (!this.dragging) {
      this.cleanup()
      return
    }
    this.suppressClick()
    const target = this.target
    const after = this.after
    this.clearPlaceholder()

    if (target) {
      const prior = [...this.container.querySelectorAll(":scope > [data-initiative-id]")].map(
        (c) => c.dataset.initiativeId,
      )
      const dragged = this.card.dataset.initiativeId
      const order = prior.filter((id) => id !== dragged)
      const ti = order.indexOf(target.dataset.initiativeId)
      order.splice(after ? ti + 1 : ti, 0, dragged)
      this.persistAndPush(order, prior)
    }
    this.cleanup()
  },
  persistAndPush(order, prior) {
    // A drop lands you in manual mode; the server persists the order onto
    // the membership rows (m02.04 §2.6). Per-mode reverse memory comes from
    // the sort form's data attribute (kept fresh by InitiativeSort).
    const reverse = !!readReverseByMode()["manual"]
    const sel = document.querySelector("#initiative-sort select[name=mode]")
    const rev = document.querySelector("#initiative-sort input[name=reverse]")
    if (sel) sel.value = "manual"
    if (rev) rev.checked = reverse
    // Apply the new order at drop (§6.2) and hold it on the preserve path until
    // the reply settles. Snapshot `prior` for an honest revert on failure.
    if (this.container && this.container.id) {
      DoitState.pending.initiativeOrder = {
        wrapId: this.container.id,
        order,
        prior,
        timer: setTimeout(() => {
          // Dropped reply: release the hold (don't revert — the server is
          // authoritative; the next re-stream reconciles the order).
          if (DoitState.pending.initiativeOrder) DoitState.pending.initiativeOrder = null
        }, 8000),
      }
      reorderInitiativeCards(this.container, order)
    }
    this.pushEvent("apply_sort", {mode: "manual", reverse, order}, (reply) => {
      settlePendingInitiativeOrder(reply)
    })
  },
  abort() {
    this.cleanup()
  },
  suppressClick() {
    const swallow = (e) => {
      e.preventDefault()
      e.stopPropagation()
      document.removeEventListener("click", swallow, true)
      clearTimeout(t)
    }
    document.addEventListener("click", swallow, true)
    const t = setTimeout(() => document.removeEventListener("click", swallow, true), 50)
  },
  cleanup() {
    if (this.timer) {
      clearTimeout(this.timer)
      this.timer = null
    }
    if (this.onMove) document.removeEventListener("pointermove", this.onMove)
    if (this.onUp) document.removeEventListener("pointerup", this.onUp)
    if (this.onCancel) document.removeEventListener("pointercancel", this.onCancel)
    this.onMove = this.onUp = this.onCancel = null
    this.clearPlaceholder()
    this.ph = null
    if (this.card) this.card.style.opacity = ""
    document.body.style.userSelect = ""
    document.body.style.cursor = ""
    this.armed = false
    this.dragging = false
    this.target = null
  },
}

// A dimmed pending avatar chip for the optimistic rail add (WL3.5 Fix B),
// mirroring the rendered <.avatar> span (avatar-emboss + the rail's size/ring
// classes). data-member-id dedupes it against the server-rendered avatar;
// data-rail-avatar-echo keys it for the reply-callback pull. opacity-60 signals
// pending — the same dimmed treatment the comment/member echoes use.
function buildRailAvatarChip(echoId, a) {
  const span = document.createElement("span")
  span.className =
    "avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-5 h-5 text-[9px] ring-1 ring-white dark:ring-zinc-900 opacity-60"
  span.style.backgroundImage = a.bg || ""
  span.style.color = a.fg || ""
  span.setAttribute("data-member-id", a.uid)
  span.setAttribute("data-rail-avatar-echo", echoId)
  span.setAttribute("aria-hidden", "true")
  span.title = a.name || ""
  span.textContent = a.initials || ""
  return span
}

// Drag a Collaborator (left-rail pane) onto an Initiative rail entry to add
// them there as a viewer (m02.05 item 10). Desktop-only — touch users use the
// click menu (item 9). A real drag suppresses the row's click so the item-9
// menu won't pop; a plain click (no drag) falls through to it.
Hooks.CollaboratorDrag = {
  mounted() {
    this.userId = this.el.dataset.userId
    this.onDown = (e) => this.start(e)
    this.el.addEventListener("pointerdown", this.onDown)
  },
  destroyed() {
    this.cleanup()
    if (this.onDown) this.el.removeEventListener("pointerdown", this.onDown)
  },
  start(e) {
    if (e.pointerType === "touch") return
    if (e.button !== undefined && e.button !== 0) return
    if (this.armed || this.dragging) return
    this.startX = e.clientX
    this.startY = e.clientY
    this.pid = e.pointerId
    this.armed = true
    this.dragging = false
    this.onMove = (ev) => this.move(ev)
    this.onUp = (ev) => this.up(ev)
    this.onCancel = () => this.cleanup()
    document.addEventListener("pointermove", this.onMove)
    document.addEventListener("pointerup", this.onUp)
    document.addEventListener("pointercancel", this.onCancel)
  },
  begin() {
    this.dragging = true
    this.el.style.opacity = "0.5"
    document.body.style.userSelect = "none"
    document.body.style.cursor = "grabbing"
    // Mark the whole Initiatives box as the drop zone for the drag's lifetime
    // (item 15.7) — orientation alongside the per-entry rail-drop-target.
    this.zone = document.getElementById("rail-initiatives")
    if (this.zone) this.zone.classList.add("collab-drop-zone")
  },
  move(e) {
    if (!this.armed) return
    if (this.pid !== undefined && e.pointerId !== this.pid) return
    if (!this.dragging) {
      if (
        Math.abs(e.clientX - this.startX) < INIT_DRAG_THRESHOLD_PX &&
        Math.abs(e.clientY - this.startY) < INIT_DRAG_THRESHOLD_PX
      ) {
        return
      }
      this.begin()
    }
    const under = document.elementFromPoint(e.clientX, e.clientY)
    this.highlight(under && under.closest("[data-rail-initiative-id]"))
  },
  highlight(entry) {
    if (entry === this.target) return
    if (this.target) this.target.classList.remove("rail-drop-target")
    this.target = entry || null
    if (this.target) this.target.classList.add("rail-drop-target")
  },
  up(e) {
    if (!this.armed) return
    if (this.pid !== undefined && e.pointerId !== this.pid) return
    if (this.dragging) {
      this.suppressClick()
      if (this.target) this.optimisticAdd(this.target.dataset.railInitiativeId)
    }
    this.cleanup()
  },
  // Optimistic add (WL3.5 Fix B, §6.2): insert the dropped collaborator's
  // avatar chip into the target rail entry's avatar row AT DROP, hold it on the
  // preserve path (railAvatarAdds + the rail-avatars applier), then push and
  // reconcile on the reply — ok pulls the dimmed stand-in (the server's rail
  // refresh now carries the real avatar), failure pulls it + bonks (MUST NOT
  // LIE). An 8s safety timer self-heals a dropped reply. The chip data rides
  // this collaborator <li>'s data attributes (mirrors the rendered avatar).
  optimisticAdd(iid) {
    const uid = this.userId
    const d = this.el.dataset
    const echoId = "ra" + Date.now() + "-" + Math.random().toString(36).slice(2, 8)
    const a = {
      iid,
      uid,
      name: d.userName || "",
      initials: d.initials || "",
      bg: d.avatarBg || "",
      fg: d.avatarFg || "",
    }
    DoitState.railAvatarAdds[echoId] = a
    // Insert now so the ack is instant; the applier covers any later patch.
    const row = document.getElementById("rail-avatars-" + iid)
    const group = row && row.querySelector("[data-rail-avatar-group]")
    if (group && !group.querySelector(`[data-member-id="${uid}"]`)) {
      group.appendChild(buildRailAvatarChip(echoId, a))
    }
    const clear = () => {
      clearTimeout(timer)
      delete DoitState.railAvatarAdds[echoId]
      document.querySelectorAll(`[data-rail-avatar-echo="${echoId}"]`).forEach((n) => n.remove())
    }
    // Dropped reply → release the hold + pull the chip (server authoritative).
    const timer = setTimeout(clear, 8000)
    this.pushEvent("add_collaborator_to", {"user-id": uid, "initiative-id": iid}, (reply) => {
      clear()
      if (reply && reply.ok === false && window.DoitBonk) window.DoitBonk()
    })
  },
  suppressClick() {
    const swallow = (e) => {
      e.preventDefault()
      e.stopPropagation()
      document.removeEventListener("click", swallow, true)
      clearTimeout(t)
    }
    document.addEventListener("click", swallow, true)
    const t = setTimeout(() => document.removeEventListener("click", swallow, true), 50)
  },
  cleanup() {
    if (this.onMove) document.removeEventListener("pointermove", this.onMove)
    if (this.onUp) document.removeEventListener("pointerup", this.onUp)
    if (this.onCancel) document.removeEventListener("pointercancel", this.onCancel)
    this.onMove = this.onUp = this.onCancel = null
    if (this.target) this.target.classList.remove("rail-drop-target")
    this.target = null
    if (this.zone) this.zone.classList.remove("collab-drop-zone")
    this.zone = null
    this.el.style.opacity = ""
    document.body.style.userSelect = ""
    document.body.style.cursor = ""
    this.armed = false
    this.dragging = false
  },
}

// Drag a member from the Members panel onto a task row to assign them
// (m02.05 item 12.8). Pointer-based, mirroring CollaboratorDrag: arm on the
// handle's pointerdown, begin past the threshold, highlight the [data-task-id]
// row under the cursor, and on release push assign_member with a reply. Honest
// optimism (item 12.5): the target row shows the "saving" hue while the write
// is in flight; the server patch lands the assignee chip (or a flash on an
// illegal drop). The assignee select / co-list stay the a11y + touch path.
Hooks.MemberDrag = {
  mounted() {
    this.userId = this.el.dataset.userId
    this.onDown = (e) => this.start(e)
    this.el.addEventListener("pointerdown", this.onDown)
  },
  destroyed() {
    this.cleanup()
    if (this.onDown) this.el.removeEventListener("pointerdown", this.onDown)
  },
  start(e) {
    if (e.pointerType === "touch") return
    if (e.button !== undefined && e.button !== 0) return
    if (this.armed || this.dragging) return
    this.startX = e.clientX
    this.startY = e.clientY
    this.pid = e.pointerId
    this.armed = true
    this.dragging = false
    this.onMove = (ev) => this.move(ev)
    this.onUp = (ev) => this.up(ev)
    this.onCancel = () => this.cleanup()
    document.addEventListener("pointermove", this.onMove)
    document.addEventListener("pointerup", this.onUp)
    document.addEventListener("pointercancel", this.onCancel)
  },
  begin() {
    this.dragging = true
    this.el.style.opacity = "0.5"
    document.body.style.userSelect = "none"
    document.body.style.cursor = "grabbing"
  },
  move(e) {
    if (!this.armed) return
    if (this.pid !== undefined && e.pointerId !== this.pid) return
    if (!this.dragging) {
      if (
        Math.abs(e.clientX - this.startX) < INIT_DRAG_THRESHOLD_PX &&
        Math.abs(e.clientY - this.startY) < INIT_DRAG_THRESHOLD_PX
      ) {
        return
      }
      this.begin()
    }
    const under = document.elementFromPoint(e.clientX, e.clientY)
    this.highlight(under && under.closest("[data-task-id]"))
  },
  highlight(row) {
    if (row === this.target) return
    if (this.target) this.target.classList.remove("member-drop-target")
    this.target = row || null
    if (this.target) this.target.classList.add("member-drop-target")
  },
  up(e) {
    if (!this.armed) return
    if (this.pid !== undefined && e.pointerId !== this.pid) return
    if (this.dragging && this.target) {
      const row = this.target
      const taskId = row.dataset.taskId
      // Optimistic assign (item 14.2): fill the primary pill now when the task
      // has none; the server patch reconciles on success, and a rejected or
      // timed-out reply reverts — optimism must never lie (UX_GUARDRAILS §6).
      const revert = this.optimisticPrimary(row)
      row.classList.add("is-saving")
      let settled = false
      const settle = (ok) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        row.classList.remove("is-saving")
        if (!ok && revert) revert()
      }
      const timer = setTimeout(() => settle(false), CO_REPLY_TIMEOUT_MS)
      this.pushEvent("assign_member", { "user-id": this.userId, "task-id": taskId }, (reply) =>
        settle(!!(reply && reply.ok)),
      )
    }
    this.cleanup()
  },
  // Fill the assignee pill's PRIMARY slot from the dragged member's data, but
  // only when the task has no primary yet — an already-assigned task gets a
  // co-assignee, whose avatar stack the server patch renders (not predicted
  // here). Returns a revert fn (restore the empty slot) or null.
  optimisticPrimary(row) {
    const pill = row.querySelector("[data-pill='assignee']")
    if (!pill || pill.hasAttribute("data-pill-set")) return null
    const d = this.el.dataset
    if (!d.username) return null
    const span = pill.querySelector("[data-pill-text]")
    const avatar = pill.querySelector("[data-pill-avatar]")
    pill.setAttribute("data-pill-set", "")
    pill.title = "Assignee: @" + d.username
    if (span) {
      span.textContent = "@" + d.username
      span.classList.remove("line-through")
    }
    if (avatar) {
      avatar.hidden = false
      avatar.textContent = d.initials || ""
      avatar.style.backgroundImage = d.avatarBg || ""
      avatar.style.color = d.avatarFg || ""
      avatar.dataset.assigneeId = this.userId
    }
    return () => {
      pill.removeAttribute("data-pill-set")
      pill.title = "Unassigned"
      if (span) span.textContent = ""
      if (avatar) {
        avatar.hidden = true
        avatar.dataset.assigneeId = ""
      }
    }
  },
  cleanup() {
    if (this.onMove) document.removeEventListener("pointermove", this.onMove)
    if (this.onUp) document.removeEventListener("pointerup", this.onUp)
    if (this.onCancel) document.removeEventListener("pointercancel", this.onCancel)
    this.onMove = this.onUp = this.onCancel = null
    if (this.target) this.target.classList.remove("member-drop-target")
    this.target = null
    this.el.style.opacity = ""
    document.body.style.userSelect = ""
    document.body.style.cursor = ""
    this.armed = false
    this.dragging = false
  },
}

// Optimistic co-assignees (m02.05 item 12.5). The pane list (#co-assignees's
// keyed <ul>) is hook-owned (phx-update="ignore"), so add/remove/reorder apply
// at the gesture without morphdom fighting them. Each change snapshots the
// list, applies it, then pushes the server event WITH A REPLY: on {ok:false} —
// or no reply within the timeout — the snapshot is restored, so a write that
// didn't land never sticks (it can't lie). The chip + dropdown stay
// server-driven (they update on the success patch). Add synthesizes a co-row
// from the selected option's avatar data.
const CO_REPLY_TIMEOUT_MS = 8000
const CO_ROW_INNER = `
  <span class="avatar-emboss relative inline-flex flex-none items-center justify-center rounded-full font-semibold select-none w-5 h-5 text-[10px]"></span>
  <span class="flex-1 min-w-0 truncate text-zinc-700 dark:text-zinc-200"></span>
  <button type="button" data-co-move data-dir="up" aria-label="Move up" class="px-1 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 disabled:opacity-30"><span class="hero-chevron-up w-3.5 h-3.5"></span></button>
  <button type="button" data-co-move data-dir="down" aria-label="Move down" class="px-1 text-zinc-400 hover:text-zinc-700 dark:hover:text-zinc-200 disabled:opacity-30"><span class="hero-chevron-down w-3.5 h-3.5"></span></button>
  <button type="button" data-co-remove aria-label="Remove co-assignee" class="px-1 text-zinc-400 hover:text-red-600 dark:hover:text-red-400"><span class="hero-x-mark w-3.5 h-3.5"></span></button>
`

Hooks.CoAssignees = {
  mounted() {
    this.onChange = (e) => {
      const sel = e.target.closest("[data-co-add]")
      if (sel && this.el.contains(sel) && sel.value) this.add(sel)
    }
    this.onClick = (e) => {
      const rm = e.target.closest("[data-co-remove]")
      if (rm && this.el.contains(rm)) return this.remove(rm.dataset.userId)
      const mv = e.target.closest("[data-co-move]")
      if (mv && this.el.contains(mv) && !mv.disabled) this.move(mv.dataset.userId, mv.dataset.dir)
    }
    this.el.addEventListener("change", this.onChange)
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.el.removeEventListener("change", this.onChange)
    this.el.removeEventListener("click", this.onClick)
  },
  list() {
    return this.el.querySelector('[id^="co-list-"]')
  },
  rowFor(id) {
    const ul = this.list()
    return ul && ul.querySelector(`[data-co-row][data-user-id="${id}"]`)
  },
  // Snapshot the list, apply `change`, push `event` with a reply, and restore
  // the snapshot on failure or timeout — so a write that didn't land reverts.
  commit(event, payload, change) {
    const ul = this.list()
    if (!ul) return
    const snapshot = ul.innerHTML
    change(ul)
    this.refreshDisabled(ul)
    let settled = false
    const finish = (ok) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      if (!ok) ul.innerHTML = snapshot
    }
    const timer = setTimeout(() => finish(false), CO_REPLY_TIMEOUT_MS)
    this.pushEvent(event, payload, (reply) => finish(!!(reply && reply.ok)))
  },
  add(sel) {
    const id = sel.value
    const data = sel.options[sel.selectedIndex].dataset
    sel.value = ""
    if (this.rowFor(id)) return
    this.commit("add_co_assignee", {user_id: id}, (ul) => {
      const empty = ul.querySelector("[data-co-empty]")
      if (empty) empty.remove()
      ul.appendChild(this.buildRow(id, data))
    })
  },
  remove(id) {
    const row = this.rowFor(id)
    if (!row) return
    this.commit("remove_co_assignee", {"user-id": id}, (ul) => {
      row.remove()
      if (!ul.querySelector("[data-co-row]")) ul.appendChild(this.emptyRow())
    })
  },
  move(id, dir) {
    const row = this.rowFor(id)
    if (!row) return
    const sib = dir === "up" ? row.previousElementSibling : row.nextElementSibling
    if (!sib || !sib.hasAttribute("data-co-row")) return
    this.commit("move_co_assignee", {"user-id": id, dir}, () => {
      if (dir === "up") row.parentNode.insertBefore(row, sib)
      else row.parentNode.insertBefore(sib, row)
    })
  },
  refreshDisabled(ul) {
    const rows = [...ul.querySelectorAll("[data-co-row]")]
    rows.forEach((li, i) => {
      const up = li.querySelector("[data-dir='up']")
      const down = li.querySelector("[data-dir='down']")
      if (up) up.disabled = i === 0
      if (down) down.disabled = i === rows.length - 1
    })
  },
  emptyRow() {
    const li = document.createElement("li")
    li.setAttribute("data-co-empty", "")
    li.className = "text-xs text-zinc-400 dark:text-zinc-500 italic"
    li.textContent = "None yet."
    return li
  },
  buildRow(id, data) {
    const li = document.createElement("li")
    li.id = "co-row-" + id
    li.setAttribute("data-co-row", "")
    li.dataset.userId = id
    li.dataset.name = data.name || ""
    li.dataset.initials = data.initials || ""
    li.dataset.avatarBg = data.avatarBg || ""
    li.dataset.avatarFg = data.avatarFg || ""
    li.className = "flex items-center gap-2 text-sm"
    li.innerHTML = CO_ROW_INNER
    const avatar = li.querySelector(".avatar-emboss")
    if (avatar) {
      avatar.textContent = data.initials || ""
      avatar.style.backgroundImage = data.avatarBg || ""
      avatar.style.color = data.avatarFg || ""
    }
    const name = li.querySelector(".flex-1")
    if (name) name.textContent = "@" + (data.name || "")
    li.querySelectorAll("[data-co-move], [data-co-remove]").forEach((b) => (b.dataset.userId = id))
    const rm = li.querySelector("[data-co-remove]")
    if (rm) rm.setAttribute("aria-label", "Remove co-assignee @" + (data.name || ""))
    return li
  },
}

// Scroll the element into view when it's the URL's hash target — e.g. the
// "User Preferences" menu item links to /account#account-preferences. LiveView
// `navigate` doesn't reliably scroll to a fragment on its own (it's a JS
// navigation, not a page load), so we do it on mount (arriving from another
// page) and on hashchange (same-page).
Hooks.ScrollOnHash = {
  mounted() {
    this.maybeScroll()
    this.onHash = () => this.maybeScroll()
    window.addEventListener("hashchange", this.onHash)
  },
  destroyed() {
    window.removeEventListener("hashchange", this.onHash)
  },
  maybeScroll() {
    if (window.location.hash === "#" + this.el.id) {
      this.el.scrollIntoView({behavior: "smooth", block: "start"})
    }
  },
}

// The keyboard-shortcuts help overlay. Toggled by a "doit:shortcuts-toggle"
// event (dispatched by the `?` key or the ⌨ affordance); closed by Escape, the
// backdrop, or the X (anything with [data-close]).
Hooks.ShortcutsOverlay = {
  mounted() {
    this.onToggle = () => this.el.classList.toggle("hidden")
    this.onKey = (e) => {
      if (e.key === "Escape" && !this.el.classList.contains("hidden")) this.el.classList.add("hidden")
    }
    this.onClick = (e) => {
      if (e.target.closest("[data-close]")) this.el.classList.add("hidden")
    }
    this.el.addEventListener("doit:shortcuts-toggle", this.onToggle)
    this.el.addEventListener("click", this.onClick)
    window.addEventListener("keydown", this.onKey)
  },
  destroyed() {
    this.el.removeEventListener("doit:shortcuts-toggle", this.onToggle)
    this.el.removeEventListener("click", this.onClick)
    window.removeEventListener("keydown", this.onKey)
  },
}

// Per-(task, mode) memory for the Reverse checkbox in the Sort menu.
// localStorage is per-browser/per-user; the actual sort_reverse on the
// task is still server-side and shared. Listener runs in capture phase
// on the form for both `input` AND `change` — LiveView's delegated
// handler fires on window-bubble for both event types, and `input`
// fires first on a <select>, so we have to beat it on `input`.
Hooks.SortRecall = {
  mounted() {
    // v2: clears stale entries left over from the broken-hook test
    // session that wrote keys before the capture-phase + input-event
    // fix landed.
    ensureStorageVersion("phx:sortrev", 2)
    this.taskId = this.el.dataset.taskId

    this.onChange = (e) => {
      const select = this.el.querySelector("select[name='mode']")
      const checkbox = this.el.querySelector("input[name='reverse']")
      if (!select || !checkbox) return

      if (e.target === select) {
        const m = select.value
        checkbox.checked = this.isInheritOrManual(m) ? false : this.recall(m)
        // LiveView never patches the focused element — blur so the re-render
        // (inherit label, selected option) can actually land.
        select.blur()
      } else if (e.target === checkbox) {
        this.save(select.value, checkbox.checked)
      }
    }
    this.el.addEventListener("input", this.onChange, true)
    this.el.addEventListener("change", this.onChange, true)

    // Seed localStorage from the current server state so the first
    // mode-switch-and-back lands on the user's last actual choice.
    const select = this.el.querySelector("select[name='mode']")
    const checkbox = this.el.querySelector("input[name='reverse']")
    if (select && checkbox && !this.isInheritOrManual(select.value)) {
      this.save(select.value, checkbox.checked)
    }
  },
  updated() {
    // Stable element ids (item 15.17) mean this hook no longer re-mounts per
    // task — refresh the task it keys localStorage on from the patched node.
    this.taskId = this.el.dataset.taskId
  },
  destroyed() {
    if (this.onChange) {
      this.el.removeEventListener("input", this.onChange, true)
      this.el.removeEventListener("change", this.onChange, true)
    }
  },
  isInheritOrManual(mode) { return mode === "" || mode === "manual" },
  key(mode) { return `phx:sortrev:${this.taskId}:${mode}` },
  save(mode, reverse) {
    if (this.isInheritOrManual(mode)) return
    localStorage.setItem(this.key(mode), reverse ? "1" : "0")
  },
  recall(mode) { return localStorage.getItem(this.key(mode)) === "1" },
}

// Cross-reference (%-notation) WRITE path — Wave 2: the two Details-pane inputs
// (#task-field-title / #task-field-description). The server renders value= as the
// RAW stored string (with `%<id>` tokens); we keep the EDIT box showing `%label`
// (never the raw id) and, on save, rewrite the box back to id-anchored tokens so
// update_task stores by id — a re-number never rots the reference.
//
// No `phx-update="ignore"`: the server value must keep flowing so a save reply
// (the DB re-renders value= with the freshly stored tokens) re-drives rehydrate.

// Comment READ path (Wave 3): render tokens -> links whenever the comment list
// re-renders. mounted() = pane open; updated() = a comment add/edit/delete
// refresh_selected patch (this hook on the <ul> fires updated() when its child
// <li>s patch — the same container-hook behaviour TreeWidth relies on). This is
// "the comment-list update path". renderAllRefs is idempotent + document-wide,
// so re-running refreshes every surface's labels in place.
Hooks.CommentRefs = {
  mounted() { renderAllRefs(document) },
  updated() { renderAllRefs(document) },
}

// Initiatives-index card READ path (m03.03 item 5.10): the index has no task
// tree, so nothing invoked renderAllRefs and card subtitles/descriptions showed
// raw `%<id>` tokens. This hook rides the card-list stream container —
// mounted() = index open; updated() fires when a card streams in or patches
// (the same container-hook behaviour CommentRefs relies on). Scoped to this.el:
// the card fields are its only ref surface, and with no tree loaded they render
// the neutral ↗ glyph (renderCardRefEl), never a raw id.
Hooks.CardRefs = {
  mounted() { renderAllRefs(this.el) },
  updated() { renderAllRefs(this.el) },
}

// Comment-edit textarea WRITE path (Wave 3): the server renders the stored
// `%<id>` tokens into the box; show them as `%label` for editing (mirrors
// RefField.rehydrate). Rehydrate on mount (the editor is rendered statically,
// then revealed client-side) and on updated (a comment-list refresh resets
// value= back to raw tokens). The save transform back to tokens is the
// capture-phase submit intercept on [data-comment-edit-form], NOT a blur here.
Hooks.CommentEditRef = {
  mounted() { this.rehydrate() },
  updated() { this.rehydrate() },
  rehydrate() {
    // No `%<id>` token means nothing to rehydrate — a user mid-typing `%1.5`
    // is never disturbed. (A bare `<` is ordinary prose, so test the full
    // token shape, not one char.)
    if (!/%<\d+>/.test(this.el.value)) return
    const next = rehydrate(this.el.value, refLabelOf)
    if (next !== this.el.value) this.el.value = next
  },
}

Hooks.RefField = {
  mounted() {
    // Show %label on first paint (the server-rendered value is raw tokens).
    this.rehydrate()
    // Rewrite %label -> %<id> the instant the field blurs, in the element's
    // CAPTURE phase. LiveView reads the value from its OWN `blur` listener
    // (dom_default.debounce, registered in the BUBBLE phase on this element by
    // `phx-debounce="blur"`); for a given event on its target, capture-phase
    // listeners fire before bubble-phase ones, so this transform lands before
    // LiveView serializes the form — the server receives `%<id>`, not `%1.5`.
    // The save is never blocked; when it adds/changes a ref, the server puts a
    // "Linked …" flash (item 3.5) — no client toast here.
    this.onBlurCapture = () => {
      const touched = []
      const next = transformForSave(this.el.value, resolveRefPath)
      if (next !== this.el.value) {
        this.el.value = next
        touched.push(this.el)
      }
      this.tokenizeSiblings(touched)
      // LiveView's blur flush serializes in its own handling of this same
      // event, so once the task settles the tokens are captured — flip every
      // box we tokenized straight back to label form (same pattern as the
      // submit intercept). Without this, a NO-OP save — which produces no
      // patch and therefore no rehydrate — leaves a box showing its raw
      // token indefinitely (O&C 4.7, the stuck-subtitle case).
      if (touched.length) {
        setTimeout(() => {
          touched.forEach((f) => {
            if (!/%<\d+>/.test(f.value)) return
            const back = rehydrate(f.value, refLabelOf)
            if (back !== f.value) f.value = back
            f.doitRefShown = back
          })
        }, 0)
      }
    }
    this.el.addEventListener("blur", this.onBlurCapture, true)
  },
  // Before LiveView's whole-form blur-flush serializes the form, anchor any
  // SIBLING ref field's rehydrated `%label` back to its token — otherwise the
  // flush would re-save that sibling as literal `%label`, destroying its stored
  // reference (the edited field is already tokenized above). Boxes changed here
  // join `touched` so the blur handler's post-serialization restore covers them.
  tokenizeSiblings(touched) {
    const form = this.el.form
    if (!form) return
    form.querySelectorAll('[phx-hook="RefField"]').forEach((f) => {
      if (f === this.el) return
      const t = transformForSave(f.value, resolveRefPath)
      if (t !== f.value) {
        f.value = t
        touched.push(f)
      }
    })
  },
  updated() {
    // A server patch (our own save reply, or a collab edit) resets value= to raw
    // tokens; turn them back into %label. Only when a token is present, so a user
    // mid-typing `%1.5` is never disturbed.
    this.rehydrate()
  },
  destroyed() {
    if (this.onBlurCapture) {
      this.el.removeEventListener("blur", this.onBlurCapture, true)
    }
  },
  rehydrate() {
    // No `%<id>` token means there is nothing to rehydrate — leave the box
    // (and any in-progress typing, `<` in prose included) alone.
    if (!/%<\d+>/.test(this.el.value)) return
    const next = rehydrate(this.el.value, refLabelOf)
    if (next !== this.el.value) this.el.value = next
    // Remember what the box shows so the post-patch pass (rehydrateRefFields)
    // can tell a stale derived display (safe to refresh) from the user's
    // uncommitted edits (never touched).
    this.el.doitRefShown = next
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  // Cold/first connects (especially after a dev recompile, when HEEx templates
  // JIT-warm and a mount can take ~3s) trip a tight WS budget and fall back to
  // LongPoll — which then STICKS via sessionStorage["phx:fallback:LongPoll"].
  // WS is proven working here (heartbeat replies ~900ms warm, upgrades ~7s), so
  // give the primary transport real room to win the race before falling back.
  longPollFallbackMs: 6000,
  // Halve the default 30s heartbeat so a SILENT drop that fires no browser
  // "offline" event (a server-side / half-open socket) is still detected — and
  // the reconnecting badge surfaced — within ~15s instead of up to ~30s. The
  // window "offline" listener below covers the fast (DevTools-Offline / real
  // network-loss) case instantly; this is the backstop for the rest.
  heartbeatIntervalMs: 15000,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
  // Preserve path (worklist 2): keep client-owned UI state through the morphdom
  // patch, preventively, so it's never clobbered and there's no post-hoc race.
  // This is the SOLE mechanism (worklist 2.4 retired the legacy reactive
  // re-assert machinery — the body MutationObserver, reassertClientState, and
  // the connect-lifecycle guards). The connect/reconnect join is itself a
  // morphdom patch, so these callbacks fire on it too: onNodeAdded reconciles
  // the wholesale-replaced join nodes, onPatchEnd runs the global re-asserts.
  // LV 1.1.29 exposes three relevant `dom` hooks (see live_socket.js
  // domCallbacks): onBeforeElUpdated(fromEl, toEl), onNodeAdded(el), and
  // onPatchEnd() (fires once AFTER each morphdom patch).
  //   - onBeforeElUpdated fires BEFORE morphdom commits an in-place update. Its
  //     return value is ignored by LiveView, so we reconcile `toEl` (the
  //     incoming node) in place — morphdom then copies the corrected value onto
  //     the live element and the wrong value never paints.
  //   - onNodeAdded fires AFTER morphdom inserts a node — the re-added case
  //     (reorder, reset re-stream, the initial-join replace). We seed it from
  //     the store on the freshly added element.
  //   - onPatchEnd is the home for GLOBAL re-asserts that don't fit the
  //     per-element model: presence painting (document-wide, idempotent), the
  //     structural pending-move re-apply, the confirm saving-hue safety, and the
  //     detailsOpen prune. It prunes DoitState.detailsOpen of entries whose
  //     element is gone, so a re-added <details data-keep="open"> falls back to
  //     the server default instead of reopening from a stale entry.
  // onBeforeElUpdated / onNodeAdded dispatch by `data-keep` into KeepRegistry,
  // reading DoitState.
  dom: {
    onBeforeElUpdated(_fromEl, toEl) { applyKeep(toEl, DoitState) },
    onNodeAdded(el) { applyKeep(el, DoitState) },
    onPatchEnd() {
      applyPresenceBadges()
      applyPendingMove()
      // Re-assert the drop-time Initiatives card order (WL3.5 Fix A) — a child
      // reorder hold, structural like applyPendingMove, so it lives here rather
      // than in a per-element data-keep kind.
      applyPendingInitiativeOrder()
      // %-references settle WITH the patch (O&C 4.7/4.9): re-render every
      // ref-bearing display surface — a patch resets a changed element to raw
      // token text, and some surfaces (the initiative header fields) have no
      // re-rendering hook of their own; running it post-patch, pre-paint also
      // kills the raw-token flash on save. Before the pane fill below, so the
      // fill sees rendered rows.
      renderAllRefs(document)
      // Re-fill the Details pane from the SURVIVING client selection on the
      // SETTLED DOM (WL7.3.2.6). The pane's `pane` data-keep applier reconciles
      // its `hidden` per-element, but the row-derived field fill must run AFTER
      // morphdom: a reconnect join is an in-place patch (performPatch) that
      // re-renders the pane from the server's nil selection (blank fields) and
      // would clobber a mid-patch fill — so the refill that actually lands on
      // reconnect is this post-patch global re-assert. syncPaneSkeleton is
      // idempotent: a settled, already-arrived pane is a cheap no-op (no fill),
      // a deliberately-closed pane (selectedId nil) stays hidden, and only an
      // in-flight / just-reconnected selection re-opens + row-fills the pane.
      if (window.DoitSelection) window.DoitSelection.syncPaneSkeleton()
      // …and re-derive every %-ref EDIT BOX from its server-synced raw text
      // (fresh labels after a re-number, raw ids never linger). After the pane
      // fill above, so a raw-row fill heals in the same pass.
      rehydrateRefFields()
      // While a confirm modal is up, its maybe-write hue is server-held
      // (pending_saving_ids) — disarm the client's 1.5s safety timer so it
      // can't strip the pink mid-decision. The patch that renders the modal is
      // exactly when this matters (§-finding: Proceed looked like it unpinked).
      if (document.getElementById("completion-confirm")) releaseSavingHue()
      // Evict stale detailsOpen entries (the store is otherwise add-only): once
      // an element id no longer resolves, drop it so the "open" applier won't
      // reopen a re-added <details> from a dead entry (e.g. the Delete-account
      // destructive confirm reappearing expanded after nav).
      for (const id of Object.keys(DoitState.detailsOpen)) {
        if (!document.getElementById(id)) delete DoitState.detailsOpen[id]
      }
      // Once the server has removed the dismissed archive banner, clear the
      // client flag (WL3 3.2) so a later re-raise — a fresh 100% crossing —
      // isn't suppressed by the stale dismissal.
      if (DoitState.archivePromptDismissed && !document.getElementById("archive-prompt")) {
        DoitState.archivePromptDismissed = false
      }
    },
  },
})

// Show progress bar on live navigation and form submits.
// topbar is the ORDINARY in-flight flash — a live navigate, patch, or form
// submit on an already-live page. It is NOT the dead-window signifier below;
// the two are deliberately distinct (see #conn-status).
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => {
  topbar.hide()
  // The in-flight nav (or any live event) settled — drop any nav-spinner started
  // at the gesture so a persisting control (the left-rail entry) doesn't stay
  // spinning after the destination is live.
  clearAllNavBusy()
})

// --- Connecting / dead-window signifier (UX_GUARDRAILS §6.8 + §6.9) ---------
//
// §6.8: a painted page must never "look ready but isn't." A LiveView page paints
// in ~0.1s but isn't live until the socket connects and the channel joins
// (~2.9s) — a ~2.8s dead window where input is silently lost. This badge says,
// plainly, that the page isn't interactive yet — and clears the instant it is.
//
// Distinct from the topbar above: topbar = the ordinary in-flight flash
// (navigate / patch / submit, brief and expected); #conn-status = the dead
// window only (first connect, or a dropped connection reconnecting). They never
// signify the same thing, so an ordinary flash is never mistaken for "not live."
//
// §6.9: driven off the SOCKET lifecycle (onOpen / onClose / onError), which
// fires on BOTH transports — WebSocket and the LongPoll fallback — so the
// signal never depends on the fast path. The initial channel-join completion
// (phx:page-loading-stop kind "initial") is the precise "now live" moment:
// onOpen is transport-only, but the page isn't interactive until mount renders.
const connStatusEl = document.getElementById("conn-status")
function setConnStatus(state) {
  if (!connStatusEl) return
  if (!state) { connStatusEl.hidden = true; return }
  const label = connStatusEl.querySelector("[data-conn-text]")
  // Write the text on every change so the aria-live region announces it — an
  // unhide alone doesn't reliably trigger a screen-reader announcement.
  if (label) label.textContent = state === "reconnecting" ? "Reconnecting…" : "Connecting…"
  connStatusEl.dataset.connState = state
  connStatusEl.hidden = false
}

// A LiveView page enters the dead window the instant it paints — well before the
// socket opens — so show the signifier immediately (this module runs at ~paint,
// far inside the gap). Dead views (no [data-phx-main], no socket) have nothing
// to connect to: JS never reveals the badge there, so it stays hidden and inert.
let connEverLive = false
if (document.querySelector("[data-phx-main]")) setConnStatus("connecting")

// onOpen fires when the transport (WS or LongPoll) opens. On the FIRST connect
// we keep "connecting" until the channel-join lands (below) so we don't claim
// live while mount is still rendering; on a RECONNECT the view rejoins on its
// own, so transport-open is enough to clear the reconnecting hint.
liveSocket.socket.onOpen(() => { if (connEverLive) setConnStatus(null) })
// A dropped / erroring connection re-opens the dead window — actions won't take
// until we rejoin. Before the first connect (connEverLive false) we're already
// showing "connecting", which stays the right message.
liveSocket.socket.onClose(() => setConnStatus(connEverLive ? "reconnecting" : "connecting"))
liveSocket.socket.onError(() => setConnStatus(connEverLive ? "reconnecting" : "connecting"))
// A SILENT network drop (the operator's DevTools-Offline test, or real loss)
// doesn't fire the socket's onClose/onError until the heartbeat times out — up
// to ~15s of dead window with no signifier. The browser fires "offline"
// IMMEDIATELY, so use it as the fast signal the socket lifecycle lacks: show
// the reconnecting badge at once. Only once we've been live (connEverLive) —
// before the first connect the "connecting" path above already owns the badge.
window.addEventListener("offline", () => { if (connEverLive) setConnStatus("reconnecting") })
// Network restored. If the socket actually survived the blip (a brief offline
// that never tore the channel down), clear the badge now. If it DID drop, the
// reconnect's onOpen above clears it instead — so don't force-clear here, which
// would lie "live" while still disconnected.
window.addEventListener("online", () => { if (liveSocket.socket.isConnected()) setConnStatus(null) })
// The main view's initial channel-join completed → the page is genuinely
// interactive. This is the precise end of the first dead window (it fires once
// per join; the onOpen above covers the clear on later reconnects).
window.addEventListener("phx:page-loading-stop", e => {
  if (e.detail && e.detail.kind === "initial") { connEverLive = true; setConnStatus(null) }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// Render %-references on the server-rendered (pre-connect) HTML so tokens never
// flash raw in the dead window before the tree hook mounts. Idempotent with the
// hook's own render on mount.
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => renderAllRefs(document))
} else {
  renderAllRefs(document)
}

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

