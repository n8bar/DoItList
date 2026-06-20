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

// Client-owned selection (UX_GUARDRAILS 6.5): the highlight is a DOM attribute
// + CSS, applied instantly and re-applied across re-renders by the guard
// observer below — the server only ever hears about it to load the Details
// pane. `lastId` backs the Enter toggle's "reselect what I had" behavior.
const DoitSelection = {
  id: null,
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
  // the guard observer converges instead of looping.
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
  // (not attributes) and skip the focused element, so the guard observer
  // converges and in-progress typing survives.
  syncPaneSkeleton() {
    // Selecting a task always leaves the initiative editor (.03.07.08).
    const ip = document.getElementById("initiative-editor-pane")
    if (ip && this.id && !ip.hidden) ip.hidden = true
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

    set(pane.querySelector("#task-field-title"), text("[data-task-title]"))
    // Description rides a hidden-when-empty row span (item 15.11) — fill the
    // textarea from it so the pane shows it instantly on selection, no round trip.
    set(pane.querySelector("#task-field-description"), text("[data-task-description]"))

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

// The right rail's mobile flyout state is view state (.03.07.20): `data-open`
// on #details-rail drives the overlay classes (Tailwind data-variants) and
// #pane-backdrop's visibility. Open = a task is selected or the initiative
// editor is showing — both client-known, so the flyout appears at the tap and
// the server patch just confirms the same attribute.
function syncRail() {
  const rail = document.getElementById("details-rail")
  if (!rail) return
  const ip = document.getElementById("initiative-editor-pane")
  const open = !!(DoitSelection.id || (ip && !ip.hidden))
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

  // Generic client-side <details> drivers (KeepOpen records the state).
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

// Rapid entry: clear the title after LiveView serializes the submit and stay
// focused, so consecutive adds need no clicks at all.
document.addEventListener("submit", (e) => {
  if (e.target.id !== "add-task-form") return
  const form = e.target
  const input = form.querySelector("[name='title']")
  const title = input.value.trim()
  if (title) {
    insertPendingRow(
      form.querySelector("[name='parent_id']").value,
      form.querySelector("[name='after_id']").value,
      title
    )
  }
  setTimeout(() => {
    input.value = ""
    input.focus()
  }, 0)
})

// Pane visibility flips client-instant (.03.07.08); the server patch
// confirms moments later. The initiative title click swaps panes at once,
// any close control hides both, and selecting a task hides the initiative
// editor (see DoitSelection.apply).
document.addEventListener("click", (e) => {
  const initiativePane = document.getElementById("initiative-editor-pane")
  const taskPane = document.getElementById("task-editor-pane")
  if (e.target.closest("[phx-click='edit_initiative']")) {
    DoitSelection.clear()
    if (initiativePane) initiativePane.hidden = false
    if (taskPane) taskPane.hidden = true
    syncRail()
    return
  }
  if (
    e.target.closest(
      "[phx-click='close_task'], [phx-click='close_panel'], [phx-click='close_initiative']"
    )
  ) {
    DoitSelection.clear()
    if (initiativePane) initiativePane.hidden = true
    syncRail()
  }
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
    // Everyone EXCEPT the operated row recomputes — their bars go
    // indeterminate; the operated row's bar is set optimistically below.
    markRecomputing([...subtree.slice(1), ...ancestors])
    const ev = toggle.dataset.toggleEvent
    if (!ev || !window.DoitPush) return
    applyToggleOptimism(li, toggle)
    window.DoitPush(ev, {id: li.dataset.taskId}, (reply) => {
      const failed = !reply || reply.ok === false
      if (failed) revertPendingToggle()
      else if (reply.committed !== false) window.DoitPendingToggle = null
    })
    return
  }
  // Cascade-sort to all descendants — pink the whole subtree of the selected branch.
  if (e.target.closest("[data-saving-subtree]")) {
    const li = selectedLi()
    if (li) markSaving(savingSubtree(li))
  }
})

document.addEventListener("change", (e) => {
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
      // Ancestor %s are in flight — indeterminate bars (.03.07.23).
      markRecomputing(ancestors)
    } else {
      markSaving([savingRowOf(li)])
    }
  }
})

// Optimistic row echo (UX_GUARDRAILS 6.2): a pane edit tells us exactly what
// the selected row will show after the write, so the row updates at the
// keystroke. The server patch re-renders the same values (no flicker) and a
// rejected write restores the truth. Roll-up math (ancestors, branch %) is
// never predicted — the saving hue covers that window.
document.addEventListener("input", (e) => {
  const li = selectedLi()
  const row = li && li.querySelector(":scope > [data-task-row]")
  if (!row) return
  const t = e.target
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
})

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
  // Backdrop click or Cancel — close without consequence.
  if (e.target === modal || e.target.closest("[data-delete-cancel]")) {
    modal.hidden = true
    clearSavingHue()
    return
  }
  if (e.target.closest("[data-delete-proceed]")) {
    modal.hidden = true
    clearSavingHue()
    if (modal.id === "delete-confirm") {
      const li = document.getElementById("task-" + modal.dataset.taskId)
      if (li) { markSaving(savingAncestors(li)); li.remove() }
      if (window.DoitPush) window.DoitPush("delete_task", {id: modal.dataset.taskId})
    } else if (window.DoitPush) {
      window.DoitPush("delete_initiative", {})
    }
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = openDeleteModal()
  if (modal) {
    modal.hidden = true
    clearSavingHue()
  }
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
// at the click. The hold handle survives patches via the guard observer (the
// confirm's pending-hue render resets the attributes to server truth) and
// settles exactly like a held drag: revert on cancel/failure, release on
// commit/resolve.
window.DoitPendingToggle = null

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

function applyToggleOptimism(li, toggle) {
  const row = li.querySelector(":scope > [data-task-row]")
  const bar = row && row.querySelector("[role='progressbar']")
  const done = !(toggle.getAttribute("aria-pressed") === "true")
  window.DoitPendingToggle = {
    liId: li.id,
    value: done,
    // Always knowable (.03.07.23): completing → 100, reopening → 0 — the
    // server zeroes manual_progress on every done→open transition (leaf,
    // branch, and cascade alike; see maybe_set_done_progress).
    barValue: done ? "100" : "0",
    prevBarValue: bar && bar.getAttribute("aria-valuenow"),
  }
  applyPendingToggle()
}

function pendingToggleParts(p) {
  const li = document.getElementById(p.liId)
  const row = li && li.querySelector(":scope > [data-task-row]")
  const toggle = row && row.querySelector("[data-complete-toggle]")
  return toggle ? {row, toggle} : null
}

function applyPendingToggle() {
  const p = window.DoitPendingToggle
  if (!p) return
  const parts = pendingToggleParts(p)
  if (!parts) return
  const want = String(p.value)
  if (parts.toggle.getAttribute("aria-pressed") !== want) {
    parts.toggle.setAttribute("aria-pressed", want)
    parts.toggle.setAttribute("aria-label", p.value ? "Reopen task" : "Mark task completed")
  }
  if (parts.row.hasAttribute("data-done") !== p.value) {
    parts.row.toggleAttribute("data-done", p.value)
  }
  if (p.barValue != null) setRowBar(parts.row, p.barValue)
}

function revertPendingToggle() {
  const p = window.DoitPendingToggle
  window.DoitPendingToggle = null
  if (!p) return
  const parts = pendingToggleParts(p)
  if (!parts) return
  parts.toggle.setAttribute("aria-pressed", String(!p.value))
  parts.toggle.setAttribute("aria-label", !p.value ? "Reopen task" : "Mark task completed")
  parts.row.toggleAttribute("data-done", !p.value)
  if (p.prevBarValue != null) setRowBar(parts.row, p.prevBarValue)
}

// Confirm-held optimism (§8.20): while a completion-flip confirm decides a
// drag, the optimistic placement holds. The server announces the outcome:
// "confirm-cancelled" (Cancel, click-away, or a failed Proceed) reverts the
// row to where it came from; "confirm-resolved" (modal closed via Proceed)
// releases the handle — the commit's re-render owns the row from there. A
// failed Proceed pushes both, cancelled first, so the revert still runs.
window.DoitPendingMove = null

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
// from the guard observer; insert-only-when-different, so it converges.
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

// Cancel / backdrop / Esc: revert the held placement and strip the saving hue.
function closeMoveFlipConfirmCancel() {
  const modal = document.getElementById("move-flip-confirm")
  if (modal) modal.hidden = true
  revertPendingMove()
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
    const handle = window.DoitPendingMove
    const stripHue = () =>
      document.querySelectorAll(".is-saving, .is-recomputing").forEach((el) => {
        el.classList.remove("is-saving", "is-recomputing")
      })
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

// Show/hide toggle for password inputs. Looks up the associated input by
// data-input-id, swaps its `type` attribute, and toggles which icon is
// visible (eye vs. eye-slash).
Hooks.PasswordToggle = {
  mounted() {
    const inputId = this.el.dataset.inputId
    const input = document.getElementById(inputId)
    if (!input) return
    const eye = this.el.querySelector(".password-eye")
    const eyeSlash = this.el.querySelector(".password-eye-slash")
    this.el.addEventListener("click", () => {
      const showing = input.type === "text"
      input.type = showing ? "password" : "text"
      eye.classList.toggle("hidden", !showing)
      eyeSlash.classList.toggle("hidden", showing)
      this.el.setAttribute("aria-label", showing ? "Show password" : "Hide password")
    })
  },
}

// Mobile theme toggle: one icon for the current theme; click cycles
// system → light → dark. Mirrors the desktop group — dispatches phx:set-theme
// (client theme + localStorage) and pushes set_theme for server persistence.
const THEME_ORDER = ["system", "light", "dark"]
Hooks.ThemeCycle = {
  mounted() {
    this.sync()
    this.onClick = () => this.cycle()
    this.el.addEventListener("click", this.onClick)
    this.onStorage = (e) => { if (e.key === "phx:theme") this.sync() }
    window.addEventListener("storage", this.onStorage)
  },
  destroyed() {
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
    // server-side parent, and the guard observer needs the handle to fix that
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

// Native <details> whose open state survives LiveView patches — the server
// renders it closed, so morphdom would otherwise slam it shut on every patch.
Hooks.KeepOpen = {
  mounted() {
    this._open = this.el.open
    this.el.addEventListener("toggle", () => { this._open = this.el.open })
  },
  updated() {
    if (this.el.open !== this._open) this.el.open = this._open
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

// Re-applies the persisted collapsed-peek class to a children <ul> whenever
// LiveView re-renders it. The toggle button (CollapseToggle) carries
// phx-update="ignore", so its updated() never fires after a tree refresh —
// without this hook, morphdom strips the JS-added class on every diff.
Hooks.CollapseChildren = {
  mounted() { ensureStorageVersion("phx:collapse", 1, { grandfather: true }); this.apply() },
  updated() { this.apply() },
  apply() {
    const key = `phx:collapse:${this.el.dataset.initiativeId}:${this.el.dataset.taskId}`
    const collapsed = localStorage.getItem(key) === "1"
    this.el.classList.toggle("collapsed-peek", collapsed)
  },
}

// Selection-presence badges (m02.04 §1.12). The server pushes the full
// "who has what selected" list (other members only); this hook stores it
// window-level and paints [data-presence-slot] spans. Like collapse state,
// the painted DOM is client-owned — the patch guard below re-applies it
// after any morphdom pass wipes a slot.
Hooks.PresenceBadges = {
  mounted() {
    window.DoitPresence = { selections: [], online: [] }
    this.handleEvent("presence-selections", ({ selections, online }) => {
      window.DoitPresence.selections = selections
      window.DoitPresence.online = online || []
      applyPresenceBadges()
    })
  },
  destroyed() {
    window.DoitPresence = { selections: [], online: [] }
  },
}

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

// The net under the hooks above: collapse state's source of truth is
// localStorage and the server never renders collapsed-peek, but per-hook
// updated() callbacks miss some patch paths (nodes moved optimistically by
// DragReorder then reconciled by morphdom, replaced subtrees) — which
// expanded collapsed branches on sort/reorder. After ANY class/childList
// change in the document, re-apply every collapse state. classList.toggle
// with a no-op force doesn't write the attribute, so this converges instead
// of looping.
function applyCollapseStates() {
  document.querySelectorAll("ul[id^='children-']").forEach((ul) => {
    const key = `phx:collapse:${ul.dataset.initiativeId}:${ul.dataset.taskId}`
    const collapsed = localStorage.getItem(key) === "1"
    ul.classList.toggle("collapsed-peek", collapsed)
    const btn = document.getElementById(`collapse-${ul.dataset.taskId}`)
    if (btn) btn.setAttribute("aria-expanded", String(!collapsed))
  })
}
let collapseGuardRaf = null
new MutationObserver(() => {
  if (collapseGuardRaf) return
  collapseGuardRaf = requestAnimationFrame(() => {
    collapseGuardRaf = null
    applyCollapseStates()
    // Selection is client-owned too — re-assert it across the same patch paths.
    window.DoitSelection.apply()
    // Confirm-held optimism (§8.20 / .03.07.22) survives the same way.
    applyPendingMove()
    applyPendingToggle()
    // Presence badges are client-painted (m02.04 §1.12) — same guard.
    applyPresenceBadges()
    // While a confirm modal is up, its maybe-write hue is server-held —
    // disarm the client's safety timer so it can't strip it mid-decision.
    if (document.getElementById("completion-confirm")) releaseSavingHue()
  })
}).observe(document.body, {
  subtree: true,
  childList: true,
  attributes: true,
  // data-selected: morphdom strips the client-set attr on patch; both
  // re-applies are idempotent (no write when correct), so no loops.
  attributeFilter: ["class", "data-selected"],
})

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
  },
  updated() { this.schedule() },
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
// the sibling fade overlays can read them as group-data-* variants (CSS owns
// show/hide — no animation-timeline, for cross-browser safety). The overlays
// are pointer-events-none, so this is purely decorative state.
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
    this.pushEvent("apply_sort", {
      mode: this.sel.value || "",
      reverse: !!this.reverseByMode[this.sel.value],
    })
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
  const d = document.getElementById((e.detail && e.detail.id) || "")
  if (!d) return
  d.open = false
  const form = d.querySelector("form")
  if (form) form.reset()
})

// Drag-to-reorder the Initiatives index (.06.3). The grove icon is the handle;
// dropping inserts the card before/after another (no reparent / center drop).
// The new order is pushed as apply_sort (mode "manual") and the server
// persists it onto the membership rows (m02.04 §2.6). Reuses the
// pointer-event pattern from DragReorder, in a simpler reorder-only form.
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
      const ids = [...this.container.querySelectorAll(":scope > [data-initiative-id]")].map(
        (c) => c.dataset.initiativeId,
      )
      const dragged = this.card.dataset.initiativeId
      const order = ids.filter((id) => id !== dragged)
      const ti = order.indexOf(target.dataset.initiativeId)
      order.splice(after ? ti + 1 : ti, 0, dragged)
      this.persistAndPush(order)
    }
    this.cleanup()
  },
  persistAndPush(order) {
    // A drop lands you in manual mode; the server persists the order onto
    // the membership rows (m02.04 §2.6). Per-mode reverse memory comes from
    // the sort form's data attribute (kept fresh by InitiativeSort).
    const reverse = !!readReverseByMode()["manual"]
    const sel = document.querySelector("#initiative-sort select[name=mode]")
    const rev = document.querySelector("#initiative-sort input[name=reverse]")
    if (sel) sel.value = "manual"
    if (rev) rev.checked = reverse
    this.pushEvent("apply_sort", {mode: "manual", reverse, order})
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
      if (this.target) {
        this.pushEvent("add_collaborator_to", {
          "user-id": this.userId,
          "initiative-id": this.target.dataset.railInitiativeId,
        })
      }
    }
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

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

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

