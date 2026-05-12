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
// Uses pointer events (not HTML5 drag-and-drop) so we can render a custom
// indent-guide and so the same gesture loop works for mobile (item 8) and
// the cross-pane gesture in Arc 4 item 11.
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
//     -- pointermove --> update anchor row + indent-guide + drop semantic
//     -- pointerup in snap-back band --> IDLE (no commit)
//     -- pointerup elsewhere --> push "move_task" event, then IDLE
//     -- pointercancel / Escape --> IDLE (no commit)
//
// Drop-target resolution:
//
//   Cursor's vertical position picks the "anchor" row (elementFromPoint).
//   Cursor's horizontal position relative to the anchor's depth picks
//   the resulting depth:
//
//     left band (<= anchor_indent - SNAP_BAND_PX):
//       sibling-of-ancestor (dedent). Step out one level per INDENT_STEP_PX
//       to the left of the anchor's natural indent.
//     middle band (within ±SNAP_BAND_PX of anchor's indent):
//       SNAP-BACK — drop here aborts (item 5).
//     right band (>= anchor_indent + SNAP_BAND_PX):
//       child-of-anchor (item 3 default). Cursor far enough right past a
//       previous sibling's indent indents under that previous sibling
//       (item 4 indent semantics).
const SNAP_BAND_PX = 32 // half-width of the snap-back band around anchor's indent
const INDENT_STEP_PX = 24 // px per depth level for indent-guide / dedent steps
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

    // Indent guide: a thin vertical line that tracks resulting depth.
    this.guide = document.createElement("div")
    this.guide.className = "drag-indent-guide"
    document.body.appendChild(this.guide)

    document.body.style.userSelect = "none"
    document.body.style.cursor = "grabbing"
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

    // Find anchor row under cursor. We hide the source briefly so
    // elementFromPoint doesn't return the dragged element itself.
    const prev = this.sourceLi && this.sourceLi.style.pointerEvents
    if (this.sourceLi) this.sourceLi.style.pointerEvents = "none"
    const target = document.elementFromPoint(e.clientX, e.clientY)
    if (this.sourceLi) this.sourceLi.style.pointerEvents = prev || ""

    const anchorLi = target && target.closest("li[data-task-id]")
    this.clearAnchorHighlight()

    if (!anchorLi || anchorLi === this.sourceLi || this.isDescendantOfSource(anchorLi)) {
      this.anchorLi = null
      this.dropPlan = null
      this.guide.style.opacity = "0"
      return
    }

    this.anchorLi = anchorLi
    this.anchorLi.classList.add("drop-target")

    // Compute drop semantic from horizontal cursor position relative to
    // the anchor row's natural left edge.
    const rowRect = anchorLi.getBoundingClientRect()
    const anchorDepth = parseInt(anchorLi.dataset.depth || "0", 10)
    const anchorIndentX = rowRect.left + anchorDepth * INDENT_STEP_PX
    const cursorOffsetX = e.clientX - anchorIndentX

    this.dropPlan = this.computeDropPlan(anchorLi, anchorDepth, cursorOffsetX)

    // Position indent guide at the resulting depth.
    const guideX = rowRect.left + this.dropPlan.depth * INDENT_STEP_PX
    this.guide.style.opacity = this.dropPlan.kind === "snap-back" ? "0.25" : "1"
    this.guide.style.transform = `translate(${guideX}px, ${rowRect.top}px)`
    this.guide.style.height = `${rowRect.height}px`
    this.guide.dataset.kind = this.dropPlan.kind
  },

  // Returns {kind, depth, parentId, position}.
  // - kind: "snap-back" | "child" | "sibling"
  // - depth: target depth (for indent-guide visual)
  // - parentId: target parent_id (null for root)
  // - position: 0-based index among siblings (or null = append)
  computeDropPlan(anchorLi, anchorDepth, cursorOffsetX) {
    // Snap-back band: middle around anchor's natural indent.
    if (Math.abs(cursorOffsetX) <= SNAP_BAND_PX) {
      return { kind: "snap-back", depth: anchorDepth, parentId: null, position: null }
    }

    if (cursorOffsetX >= SNAP_BAND_PX) {
      // RIGHT band — child-of-anchor (default). Further right indents under
      // the anchor's previous sibling if the cursor passes its depth + step.
      const prevSibling = this.previousSibling(anchorLi)
      if (prevSibling && cursorOffsetX >= SNAP_BAND_PX + INDENT_STEP_PX) {
        const prevId = parseInt(prevSibling.dataset.taskId, 10)
        const prevDepth = parseInt(prevSibling.dataset.depth || "0", 10)
        return {
          kind: "child",
          depth: prevDepth + 1,
          parentId: prevId,
          position: null,
        }
      }
      const anchorId = parseInt(anchorLi.dataset.taskId, 10)
      return { kind: "child", depth: anchorDepth + 1, parentId: anchorId, position: null }
    }

    // LEFT band — dedent. Step out one ancestor per INDENT_STEP_PX past the
    // band edge. Result: become a sibling of an ancestor (or root).
    const stepsLeft = Math.floor((-cursorOffsetX - SNAP_BAND_PX) / INDENT_STEP_PX) + 1
    let ancestor = anchorLi
    for (let i = 0; i < stepsLeft && ancestor; i++) {
      const parentLi = ancestor.parentElement && ancestor.parentElement.closest("li[data-task-id]")
      if (!parentLi) {
        ancestor = null
        break
      }
      ancestor = parentLi
    }
    if (!ancestor) {
      // Clamp at root: insert as sibling of anchor's root ancestor.
      return { kind: "sibling", depth: 0, parentId: null, position: null }
    }
    const ancestorParent = this.parentTaskOf(ancestor)
    const ancestorDepth = parseInt(ancestor.dataset.depth || "0", 10)
    return {
      kind: "sibling",
      depth: ancestorDepth,
      parentId: ancestorParent,
      position: null, // append after this ancestor — server will normalize
    }
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

    const plan = this.dropPlan
    if (!plan || plan.kind === "snap-back" || !this.sourceLi) {
      this.cleanup()
      return
    }

    const taskId = parseInt(this.sourceLi.dataset.taskId, 10)
    const params = {
      task_id: taskId,
      parent_id: plan.parentId,
      position: plan.position,
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

  cleanup() {
    this.clearLongPressTimer()
    this.clearPrimingCue()

    if (this.onMove) document.removeEventListener("pointermove", this.onMove)
    if (this.onUp) document.removeEventListener("pointerup", this.onUp)
    if (this.onCancel) document.removeEventListener("pointercancel", this.onCancel)
    if (this.onKeyDown) document.removeEventListener("keydown", this.onKeyDown)
    this.onMove = this.onUp = this.onCancel = this.onKeyDown = null

    this.clearAnchorHighlight()
    if (this.sourceLi) this.sourceLi.classList.remove("dragging-source")
    this.sourceLi = null
    if (this.guide && this.guide.parentNode) this.guide.parentNode.removeChild(this.guide)
    this.guide = null

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
  },

  // ---- Tree helpers ------------------------------------------------------
  isDescendantOfSource(li) {
    return this.sourceLi && this.sourceLi.contains(li)
  },

  // Previous sibling task <li> in the same <ul>, skipping non-task nodes
  // (e.g. inline "add task" forms).
  previousSibling(li) {
    let n = li.previousElementSibling
    while (n && !n.dataset.taskId) n = n.previousElementSibling
    return n
  },

  // The parent task id of a row's <li>, or null if it's a root task.
  parentTaskOf(li) {
    const parentLi = li.parentElement && li.parentElement.closest("li[data-task-id]")
    return parentLi ? parseInt(parentLi.dataset.taskId, 10) : null
  },
}

// Per-task collapse/expand toggle for the task tree on /initiatives/:id.
// Persists state in localStorage keyed by (initiative_id, task_id).
// Toggling never affects roll-up — it only hides the children <ul>.
Hooks.CollapseToggle = {
  mounted() { this.bind(); this.apply() },
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

