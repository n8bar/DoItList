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
  savingPending.forEach((el) => el.classList.remove("is-saving"))
  savingPending.clear()
  if (savingTimer) { clearTimeout(savingTimer); savingTimer = null }
}

const selectedLi = () => document.querySelector("li[data-selected]")

// The colocated TaskKeys hook can't import, so reach it through the window.
window.DoitSaving = {markSaving, savingAncestors, savingSubtree, savingChildren, selectedLi, savingRowOf}

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
    if (!pane) return
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
    if (inFlight) this.fillPaneFields(pane)
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

    // The priority pill shows the value when ≠ normal; the title attr always
    // carries it ("Priority: high").
    const priEl = row.querySelector("[phx-value-focus='priority']")
    const pri = priEl ? (priEl.getAttribute("title") || "").replace("Priority: ", "") : ""
    if (pri) set(pane.querySelector("#task-field-priority"), pri)

    const wText = text("[phx-value-focus='weight']")
    set(pane.querySelector("#task-field-weight"), wText.startsWith("w=") ? wText.slice(2) : "1.0")

    // Match the assignee option by its visible name (the pill shows "@name").
    const aSelect = pane.querySelector("#task-field-assignee")
    const aText = text("[phx-value-focus='assignee']")
    if (aSelect && aSelect !== document.activeElement) {
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
  },
}
window.DoitSelection = DoitSelection

// The one add-task form (UX_GUARDRAILS 6.5): opening, placing, and closing
// it never touches the server. It teleports between phx-update="ignore"
// slots, so no patch can disturb it mid-typing; create_task reads the two
// hidden inputs the client sets here.
const DoitAddForm = {
  form() { return document.getElementById("add-task-form") },
  open(slot, parentId, afterId, placeholder) {
    const form = this.form()
    if (!form || !slot) return
    slot.appendChild(form)
    form.querySelector("[name='parent_id']").value = parentId || ""
    form.querySelector("[name='after_id']").value = afterId || ""
    const input = form.querySelector("[name='title']")
    input.placeholder = placeholder
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
  close() {
    const form = this.form()
    const home = document.getElementById("add-task-home")
    if (form && home) home.appendChild(form)
  },
}
window.DoitAddForm = DoitAddForm

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
})

// Rapid entry: clear the title after LiveView serializes the submit and stay
// focused, so consecutive adds need no clicks at all.
document.addEventListener("submit", (e) => {
  if (e.target.id !== "add-task-form") return
  const input = e.target.querySelector("[name='title']")
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
    return
  }
  if (
    e.target.closest(
      "[phx-click='close_task'], [phx-click='close_panel'], [phx-click='close_initiative']"
    )
  ) {
    DoitSelection.clear()
    if (initiativePane) initiativePane.hidden = true
  }
})

// Row clicks: selection toggles instantly client-side; the server event only
// drives the Details pane. Pills (phx-value-focus) keep their own phx-click
// (select + focus a field) and never toggle the selection closed.
document.addEventListener("click", (e) => {
  const row = e.target.closest("[data-task-row]")
  if (!row || !window.DoitPush) return
  // Interactive children (toggle, collapse, pills, drag handle) own their
  // clicks; pills additionally select without toggling. The check must stay
  // inside the row — ancestors (children <ul>s, the page root) carry hooks.
  const interactive = e.target.closest("button, a, form, [phx-hook]")
  if (interactive && interactive !== row && row.contains(interactive)) {
    if (e.target.closest("[phx-value-focus]")) {
      const li = row.closest("li[data-task-id]")
      if (li) DoitSelection.set(li.dataset.taskId)
    }
    return
  }
  const li = row.closest("li[data-task-id]")
  if (!li) return
  const id = li.dataset.taskId
  if (DoitSelection.id === id) {
    DoitSelection.clear()
    window.DoitPush("close_task", {})
  } else {
    DoitSelection.set(id)
    window.DoitPush("select_task", {id: id})
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
  // the ancestor chain whose progress / status recomputes.
  const toggle = e.target.closest("[data-complete-toggle]")
  if (toggle) {
    const li = toggle.closest(SAVING_ROW)
    if (li) markSaving([...savingSubtree(li), ...savingAncestors(li)])
    // Leaf toggles flip the checkbox optimistically (§8.18.1 judgment): its
    // styling keys off aria-pressed, so one attribute write does it. Leaf
    // toggles commit directly — no confirm class covers them — so nothing can
    // intercept the flip. Branch toggles (cascade_*) stay server-timed: they
    // may open a confirm, and their flip belongs to the cascade's outcome.
    if (toggle.getAttribute("phx-click") === "toggle_complete") {
      const pressed = toggle.getAttribute("aria-pressed") === "true"
      toggle.setAttribute("aria-pressed", String(!pressed))
      toggle.setAttribute("aria-label", pressed ? "Mark task completed" : "Reopen task")
    }
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
  // Details attribute fields — pink the edited row; weight rolls up, so its
  // ancestors pink too. Priority / assignee don't roll up. Title / description
  // are intentionally excluded (not part of .03.03.08's attribute scope).
  if (["task-field-priority", "task-field-weight", "task-field-assignee"].includes(e.target.id)) {
    const li = selectedLi()
    if (!li) return
    const rollup = e.target.id === "task-field-weight"
    markSaving(rollup ? [savingRowOf(li), ...savingAncestors(li)] : [savingRowOf(li)])
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
      const pill = row.querySelector("[phx-value-focus='priority']")
      if (!pill) return
      const set = t.value !== "normal"
      pill.toggleAttribute("data-pill-set", set)
      pill.textContent = set ? t.value : ""
      pill.title = "Priority: " + t.value
      return
    }
    case "task-field-weight": {
      const pill = row.querySelector("[phx-value-focus='weight']")
      if (!pill) return
      const v = t.value.trim()
      const set = v !== "" && parseFloat(v) !== 1
      pill.toggleAttribute("data-pill-set", set)
      pill.textContent = set ? "w=" + v : ""
      if (v !== "") pill.title = "Weight " + v
      return
    }
    case "task-field-assignee": {
      const pill = row.querySelector("[phx-value-focus='assignee']")
      const span = pill && pill.querySelector("span")
      if (!span) return
      const name = t.value ? t.options[t.selectedIndex].textContent.trim() : ""
      pill.toggleAttribute("data-pill-set", !!name)
      span.textContent = name ? "@" + name : ""
      pill.title = name ? "Assignee: " + name : "Unassigned"
      return
    }
    case "task-field-progress": {
      const readout = document.querySelector("#task-editor-pane [data-progress-readout]")
      if (readout) readout.textContent = t.value
      // The slider only writes a leaf's bar; a done leaf displays 100
      // regardless of the manual value, so leave it to the server.
      const done = row.querySelector("[data-complete-toggle][aria-pressed='true']")
      if (done) return
      const bar = row.querySelector("[role='progressbar']")
      if (!bar) return
      bar.style.setProperty("--progress", t.value + "%")
      bar.setAttribute("aria-valuenow", t.value)
      const txt = bar.querySelector(".progress-bar-text")
      if (txt) txt.textContent = t.value + "%"
      return
    }
  }
})

// Client-instant delete confirm (.03.07.15, UX_GUARDRAILS 6.5): the dialog's
// whole content is already client-known, so it opens at the click — no round
// trip before the user can decide. The subtree holds a sticky maybe-write hue
// while the dialog is up; Cancel clears it, Delete optimistically removes the
// row (pinking the surviving ancestors) and pushes the actual delete.
document.addEventListener("click", (e) => {
  const modal = document.getElementById("delete-confirm")
  if (!modal) return
  if (e.target.closest("#delete-task-btn")) {
    const li = selectedLi()
    if (!li) return
    modal.dataset.taskId = li.dataset.taskId
    const title = li.querySelector(":scope > [data-task-row] [data-task-title]")
    modal.querySelector("[data-delete-title]").textContent = title ? title.textContent.trim() : ""
    markSaving(savingSubtree(li), {sticky: true})
    modal.hidden = false
    const cancel = modal.querySelector("[data-delete-cancel]")
    if (cancel) cancel.focus()
    return
  }
  if (modal.hidden) return
  // Backdrop click or Cancel — close without consequence.
  if (e.target === modal || e.target.closest("[data-delete-cancel]")) {
    modal.hidden = true
    clearSavingHue()
    const btn = document.getElementById("delete-task-btn")
    if (btn) btn.focus()
    return
  }
  if (e.target.closest("[data-delete-proceed]")) {
    modal.hidden = true
    clearSavingHue()
    const li = document.getElementById("task-" + modal.dataset.taskId)
    if (li) { markSaving(savingAncestors(li)); li.remove() }
    if (window.DoitPush) window.DoitPush("delete_task", {id: modal.dataset.taskId})
  }
})

document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return
  const modal = document.getElementById("delete-confirm")
  if (modal && !modal.hidden) {
    modal.hidden = true
    clearSavingHue()
  }
})

// Confirm-held optimism (§8.20): while a completion-flip confirm decides a
// drag, the optimistic placement holds. The server announces the outcome:
// "confirm-cancelled" (Cancel, click-away, or a failed Proceed) reverts the
// row to where it came from; "confirm-resolved" (modal closed via Proceed)
// releases the handle — the commit's re-render owns the row from there. A
// failed Proceed pushes both, cancelled first, so the revert still runs.
window.DoitPendingMove = null

// Re-assert the held placement: server-side the row still belongs to its old
// parent, so every patch that touches either child list moves it back. Runs
// from the guard observer; insert-only-when-different, so it converges.
function applyPendingMove() {
  const p = window.DoitPendingMove
  if (!p || !p.destContainer) return
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
window.addEventListener("phx:confirm-cancelled", () => {
  const p = window.DoitPendingMove
  window.DoitPendingMove = null
  if (!p || !p.parent || !p.parent.isConnected) return
  // The original next-sibling may have been re-rendered away; fall back to
  // appending rather than throwing.
  const next = p.next && p.next.parentElement === p.parent ? p.next : null
  p.parent.insertBefore(p.li, next)
  if (p.fabricatedUl && p.fabricatedUl.children.length === 0) p.fabricatedUl.remove()
})
window.addEventListener("phx:confirm-resolved", () => {
  window.DoitPendingMove = null
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
        if (sourceParentLi) extra.push(sourceParentLi.firstElementChild)
        if (destParentLi) extra.push(destParentLi.firstElementChild)
      }
      this.markSaving(dest.container, extra)
    }

    const fabricatedUl = this._fabricatedUl
    this._fabricatedUl = null
    const movedLi = this.sourceLi
    const held = {}
    this.pushEvent("move_task", params, (reply) => {
      const failed = !reply || reply.ok === false
      // A failed write snaps the row back — the server re-renders the
      // unchanged tree.
      if (failed && origParent) {
        origParent.insertBefore(movedLi, origNext)
        // Drop any empty child list we fabricated for an optimistic reparent.
        if (fabricatedUl && fabricatedUl.children.length === 0) fabricatedUl.remove()
      }
      // A move awaiting completion-flip confirmation (committed: false) HOLDS
      // its optimistic placement while the modal decides (§8.20 — confirms
      // must not undo optimism). Server-side the row still lives under its
      // old parent, so any patch (the pending-hue render included) puts it
      // back; the guard observer re-asserts the held spot until the
      // "confirm-cancelled" / "confirm-resolved" listeners below release it.
      if (!failed && reply.committed === false) {
        window.DoitPendingMove = {
          li: movedLi,
          parent: origParent,
          next: origNext,
          fabricatedUl,
          destContainer: held.container,
          destNext: held.next,
        }
        applyPendingMove()
      }
      // Clear the hue explicitly on the server's reply — don't rely on morphdom
      // stripping it, which is unreliable once we've moved the DOM ourselves.
      this.clearSaving()
    })
    this.cleanup()
    // Captured after cleanup so the drop placeholder (the pre-cleanup
    // nextSibling) doesn't pollute the held position.
    held.container = movedLi.parentElement
    held.next = movedLi.nextElementSibling
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
    if (this._saving) this._saving.forEach((el) => el.classList.remove("is-saving"))
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
    // A confirm-held drag placement (§8.20) survives the same way.
    applyPendingMove()
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

// Initiatives-index sort control. The preference (mode + reverse + manual drag
// order) lives in localStorage — per-user, per-browser, no schema (worklist 6;
// recapture as server prefs later, see BACKLOG). On mount we seed the controls
// from storage and push apply_sort so the server sorts + re-streams; on change
// we persist and re-push. The drag hook writes the same key's `order`.
const INIT_SORT_KEY = "doit:init-sort"
function readInitSort() {
  try {
    return JSON.parse(localStorage.getItem(INIT_SORT_KEY)) || {}
  } catch {
    return {}
  }
}
function writeInitSort(state) {
  localStorage.setItem(INIT_SORT_KEY, JSON.stringify(state))
}
Hooks.InitiativeSort = {
  mounted() {
    this.sel = this.el.querySelector("select[name=mode]")
    this.rev = this.el.querySelector("input[name=reverse]")
    const s = readInitSort()
    this.order = s.order || []
    // Reverse is remembered per mode, so each sort option keeps its own
    // direction. (Legacy single-boolean shape is discarded.)
    this.reverseByMode = s.reverse && typeof s.reverse === "object" ? s.reverse : {}
    this.sel.value = s.mode || ""
    this.rev.checked = !!this.reverseByMode[this.sel.value]
    this.push()

    // Switching modes reflects that mode's remembered reverse.
    this.sel.addEventListener("change", () => {
      this.rev.checked = !!this.reverseByMode[this.sel.value]
      this.persist()
      this.push()
    })
    // Toggling reverse updates only the current mode's setting.
    this.rev.addEventListener("change", () => {
      this.reverseByMode[this.sel.value] = this.rev.checked
      this.persist()
      this.push()
    })
  },
  persist() {
    writeInitSort({mode: this.sel.value || null, order: this.order, reverse: this.reverseByMode})
  },
  push() {
    this.pushEvent("apply_sort", {
      mode: this.sel.value || "",
      reverse: !!this.reverseByMode[this.sel.value],
      order: this.order,
    })
  },
}

// Drag-to-reorder the Initiatives index (.06.3). The grove icon is the handle;
// dropping inserts the card before/after another (no reparent / center drop).
// The new order is written to localStorage (mode "manual") and pushed so the
// server re-streams it. Reuses the pointer-event pattern from DragReorder, in a
// simpler reorder-only form.
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
    const s = readInitSort()
    const reverse = s.reverse && typeof s.reverse === "object" ? s.reverse : {}
    writeInitSort({mode: "manual", order, reverse})
    const sel = document.querySelector("#initiative-sort select[name=mode]")
    const rev = document.querySelector("#initiative-sort input[name=reverse]")
    if (sel) sel.value = "manual"
    if (rev) rev.checked = !!reverse["manual"]
    this.pushEvent("apply_sort", {mode: "manual", reverse: !!reverse["manual"], order})
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

// Focuses a Details-panel field on request from the server. Tapping a task's
// priority / weight / assignee chip selects the task and pushes "focus-field"
// with the target id; we focus it once the editor is in the DOM. rAF lets the
// just-patched pane lay out first; scrollIntoView handles the mobile case where
// the field sits below the fold.
Hooks.FocusField = {
  mounted() {
    this.handleEvent("focus-field", ({ id }) => {
      requestAnimationFrame(() => {
        const el = document.getElementById(id)
        if (el) {
          el.focus()
          el.scrollIntoView({ block: "nearest" })
        }
      })
    })
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

