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

    this.clearAnchorHighlight()

    // Root-level overlay zones (item 17) take priority over row anchoring.
    // A hit promotes a non-root source to the root list, or reorders a root
    // source within it: top zone → front, bottom zone → end. Either way the
    // destination is the root list, flagged reorder (item 16 pins the
    // Initiative to manual).
    const zone = this.rootZoneAt(e.clientX, e.clientY)
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
    const target = document.elementFromPoint(e.clientX, e.clientY)
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
    const band = this.bandFor(anchorLi, e.clientY)

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

    // Optimistic UI: leave the source where it is; LiveView will re-render
    // the tree on :ok. On error, the flash explains why.
    this.pushEvent("move_task", params, (reply) => {
      if (reply && reply.ok === false) {
        // Revert visual hint — server will also re-render unchanged tree.
        // No-op here beyond cleanup.
      }
    })
    this.cleanup()
  },

  abort() {
    this.cleanup()
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
  // 21). Edge bands are thin strips at the content edges; the progress underbar
  // (pinned at the row's bottom) counts as center, so it lights up the task
  // like the rest of the row. An expanded branch has NO "below" band — its
  // lower area is all center; use its tail zone for "last child" instead.
  bandFor(li, clientY) {
    const row = li.firstElementChild || li
    const rect = row.getBoundingClientRect()
    // The progress underbar marks the effective content bottom — everything
    // from there down is center.
    const bar = row.querySelector(":scope > [role=progressbar]")
    const contentBottom = bar ? bar.getBoundingClientRect().top : rect.bottom
    const EDGE = 9 // px strip at each content edge

    if (clientY < rect.top + EDGE) return "above"

    if (
      !this.hasVisibleChildren(li) &&
      clientY >= contentBottom - EDGE &&
      clientY < contentBottom
    ) {
      return "below"
    }

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

