# Client-first interaction

How Do It List keeps interactions instant. Read before building any new interactive
affordance (a write, a toggle, a pane, a control) so the feature INHERITS the pattern
instead of re-introducing a round-trip. Mechanisms live in `assets/js/app.js`; the
master-detail LiveView is `lib/doit_web/live/initiative_workspace_live.ex`.

Governing outcomes: UX_GUARDRAILS §6 (esp. 6.2/6.5/6.7/6.8/6.9) and §7.3/7.4. This doc
is the HOW; §6 is the WHAT.

## The split

- **Client owns ephemeral / view state** — selection, open/closed panes, expand/collapse,
  scroll, focus, optimistic in-flight values, presence badges. It NEVER waits on the
  network to reflect these.
- **Server owns durable data and sync** — the tasks, comments, members, prefs, and the
  authoritative result of every write. The client predicts; the server commits.

A new interaction is one of three kinds. Pick before you build:
1. **Pure view state** → client-only, no server event at all (selection, open editor, expand).
2. **Optimistic write** → apply at the gesture, reconcile on the server reply, revert on failure.
3. **Server-gated** (the client can't know the result — a permission gate, a server-side
   filter) → show an up-front in-flight signifier at the gesture; let the server's render settle it.

## 1. Where ephemeral state lives — `window.DoitState`

The single client-owned store (`DoitState`, exposed as `window.DoitState`). One object that
survives every server re-render, reconnect, and initial connect. Slices:

- `selectedId` — the selected task (backed by `DoitSelection`).
- `editorOpen` — initiative-editor visibility (backed by `DoitInitiativeEditor`).
- `detailsOpen{}` — open/closed of each `data-keep="open"` `<details>`, keyed by element id.
- `commentEditId` / `commentVersionsId` — which comment's inline editor / history popup is open.
- `pending.{toggle,move,initiativeOrder}` — optimistic structural holds (a completion flip, a
  drag-move, a drag-reordered Initiatives card order).
- `railAvatarAdds{}` — optimistic member-avatar chips, keyed by echo id.
- `assignedGrouped{}` / `revealInflight{}` / `archivePromptDismissed` — held optimistic view
  prefs / server-gated control ticks for the Assigned + Archived panes.
- `presence{}` — collaborator selection + online badges.
- `scroll{}` — captured `scrollTop` of `data-keep="scroll"` boxes.
- `preconnectQueue[]` — the dead-window capture queue (see §4).

Add a new ephemeral field HERE, not in a new `window.Doit*` object. Declare its shape even if a
later slice activates it. Focus + caret are NOT kept — every focusable lives at a stable id, so
node identity + LiveView's `restoreFocus` carry them.

Persistent client state (survives reload) goes in `localStorage`, not `DoitState` — see
`.agents/localstorage.md` for the namespace + version-sentinel convention.

## 2. The preserve path — one mechanism, no per-feature observers

Client-owned state is reconciled THROUGH every morphdom patch, preventively — never re-asserted
after the fact (no race, never paints wrong). Three parts:

1. **Marker.** The server renders `data-keep="<kind>"` on each client-owned element. The server
   always renders it at its *default* (editor hidden, details collapsed, row un-flipped); the
   client owns the live value.
2. **Applier.** `KeepRegistry[<kind>].apply(el, state)` reconciles that one element to `DoitState`,
   **idempotently** — write only when the DOM disagrees; remove the attribute/class when it
   shouldn't be there. Idempotence is mandatory: appliers run on every patch path.
3. **Dispatch.** The `LiveSocket` `dom` callbacks fan out by `el.dataset.keep`:
   - `onBeforeElUpdated(_from, toEl)` → `applyKeep(toEl)` — fix the INCOMING node before morphdom
     copies it onto the live element, so the wrong value never paints.
   - `onNodeAdded(el)` → `applyKeep(el)` — seed a freshly re-added node (reorder, reset re-stream,
     the initial-join replace).
   - `onPatchEnd()` — GLOBAL re-asserts that don't fit the per-element model (presence painting,
     `applyPendingMove`, `applyPendingInitiativeOrder`, the confirm saving-hue safety, the
     `detailsOpen` prune). Add here only when a single element can't own the reconcile.

The connect/reconnect join is itself a morphdom patch, so these fire on it too. This is the SOLE
preserve mechanism — there is no MutationObserver, no reactive re-assert.

**To make a NEW client-owned element join the path:**
1. Add its truth to `DoitState`.
2. Render `data-keep="<kind>"` on the element (one `data-keep` per element — if the element
   already holds one, put the new marker on a child, as `pending-toggle` rides the row's child).
3. Add a `KeepRegistry["<kind>"]` entry whose `apply` reconciles that element to the store,
   idempotently.
4. Record changes into `DoitState` from a delegated listener. For events that don't bubble
   (`toggle`, `scroll`) use a single document-level **capture-phase** listener so it reaches every
   target, including ones a later patch re-adds.

After a client-only flip that should show before the next patch, call `window.DoitApplyKeep(el)`
to run that element's applier immediately.

## 3. Optimistic writes — and the must-not-lie rule

Funnel EVERY server-gated write through `window.DoitPush(ev, payload, cb)`. Never call a hook's
`pushEvent` directly from a delegated listener — `DoitPush` is what makes the dead-window queue work.

Shape of an optimistic write:
1. **Apply at the gesture** — write the predicted value into `DoitState` and the DOM (or insert a
   pending node: `buildPendingRow`, `buildPendingComment`, `buildRailAvatarChip`). The preserve
   path re-holds it across mid-flight patches.
2. **Reconcile on reply** — in the `DoitPush` callback, release the hold once the server's render
   agrees (the applier clears its own `DoitState` entry on match); the server owns the element
   from there.
3. **Revert on failure** — pull the pending node / restore the prior value. A safety timeout
   (commonly 8s) self-heals a dropped reply so a ghost never sticks.

**Must not lie (UX_GUARDRAILS §6 / honesty):** never leave an optimistic reflection asserting a
success the server didn't grant. A refused add pulls its bubble; a refused edit reverts to the
saved text; a refused member-add pulls the chip. If you can't honestly predict the result, it's
not an optimistic write — make it server-gated (§4).

The completion math, flip-confirm decision, and roll-up % stay SERVER-side — predict the bare row
on the client, let the authoritative reply reconcile the tree. Don't duplicate domain logic in JS.

## 4. Server-gated acknowledgement

When the client can't know the result (a permission gate, or server-FILTERED rows the client can't
reveal alone), don't fake a value — acknowledge with an up-front **in-flight signifier** that fires
at the gesture, independent of connect:

- **`latchButton(btn, label)`** — swaps the trailing label ("Hide" → "Hiding…"), pulses, sets
  `aria-busy`, disables on the next microtask (the defer matters: a synchronous `disabled` drops
  the control from LiveView's own push). Driven by `data-latch="<label>"` on the button via the
  delegated click/submit listeners. Returns an idempotent restore; an ~8s timer self-restores.
  Use this instead of relying on `phx-disable-with` / `phx-click-loading`, which aren't attached
  until the view is live.
- **Saving hue** (`window.DoitSaving.markSaving` + `is-saving`, `markRecomputing` + `is-recomputing`)
  — pink the touched rows the instant the user acts; the authoritative render strips the class,
  with a timeout safety net. `releaseSavingHue` hands the hue to the server while a confirm modal is up.
- **Held control tick** (`revealInflight`, `assignedGrouped`) — hold the CONTROL's own checkbox +
  `aria-busy` until the server's re-render agrees; NEVER paint phantom rows. `doit-reveal-busy` is
  the connect-independent twin of `phx-click-loading` that drives the spinner.

The signifier is ONLY in-flight, never success. The action still rides its native `phx-click` /
`phx-submit` (live) or the dead-window capture (§4 below).

## 5. The dead window — interactive from first paint

A LiveView page paints ~2.8s before the channel joins. Anything done in that gap must be captured
and replayed, not dropped (UX_GUARDRAILS §6.8). Four parts:

- **`DoitPush` exists from module load.** When live (`livePush` set) it dispatches immediately;
  in the dead window it CAPTURES onto `DoitState.preconnectQueue` via `enqueuePreconnect`. The
  root hook's `mounted()` registers its bound `pushEvent` through `window.DoitRegisterLivePush`,
  which **flushes the queue in order** — registration IS the "now live" signal. So a new
  server-gated affordance that rides `DoitPush` is dead-window-safe for free.
- **Capture-phase interceptor for native `phx-*`.** Many writes ride native `phx-click` /
  `phx-submit` / `phx-change` and LiveView pushes them itself — silently dropped while dead. The
  document-level capture-phase listeners serialize the event NAME + PAYLOAD off the gesture and
  route it through the SAME queue (`preconnectSerializeForm` rebuilds the nested map Plug.Conn.Query
  would decode). We SERIALIZE and replay via `pushEvent`, never re-dispatch the gesture (the
  optimistic handler already ran). Skip lists keep it honest: `DOITPUSH_OWNED` (already delivered
  by `DoitPush`), `PRECONNECT_DESTRUCTIVE` and `data-confirm` clicks (a confirm can't run while
  dead — the user re-acts), and JS-command bindings (`phx-click={JS...}`, can't replay as an event).
  `preconnectCoalesceKey` decides replace-vs-append (singleton prefs coalesce last-write-wins;
  distinct creates/flips append).
- **Safe id parse.** A flushed/late payload reaches the server where the selection may be stale;
  `preconnectSelfTarget` folds the target id (`DoitState.selectedId`) into the payload so the edit
  lands on its own task. On the server, `parse_id/1` is the single gate for EVERY client-supplied
  id — it returns the int only for a clean, in-range binary and `nil` otherwise; handlers no-op on
  `nil` so a malformed or replayed id fails soft, never crashes the LiveView.
- **Shell / detail hook split.** The always-present **`.Workspace`** root hook owns the
  `DoitRegisterLivePush` registration — registered once at first connect, NEVER unregistered on a
  list↔detail hop, so the dead window exists ONLY at first connect. The per-Initiative
  **`.TaskKeys`** detail hook (keyed by Initiative id) mounts on detail-enter and is destroyed on
  leave/switch; it owns detail-only duties (keydown, selection replay, the detail `handleEvent`s)
  and clears leaked detail-scoped state when it detects an A→B switch. Other LiveViews mirror the
  shell pattern (`.AssignedLive`, `.AccountLive`).

New server-gated affordances MUST ride one of these paths (`DoitPush`, or a native `phx-*` the
interceptor captures) — otherwise the action is dropped pre-connect.

## 6. Master-detail navigation

One LiveView — **`InitiativeWorkspaceLive`** — serves both the list (`:index`) and a per-Initiative
detail (`:show`), routed at `/initiatives` and `/initiatives/:id`.

- A list↔detail hop is a **`push_patch`** driving **`handle_params`** with NO remount, so the
  socket, its subscriptions, and the user's presence stay intact (UX_GUARDRAILS §7.4 — no
  flicker-out-and-back for collaborators).
- `enter_initiative/3` subscribes (`Tasks.subscribe`, presence + chat topics) and `Presence.track`s
  on ENTER. Because there's no remount, these no longer ride process death — `teardown_detail/1`
  must `unsubscribe` + `Presence.untrack` EXPLICITLY on leave/switch. Re-entering the same
  Initiative (a `?task=` deep-link patch) honors the param only — it never re-subscribes.
- Guard every client-supplied `:id` through `parse_id/1` → not-found flash + `push_navigate` eject
  on `nil`/missing, never a crash.

New navigation within the app: prefer `push_patch` + `handle_params` over a remount; if you add a
subscription/track on enter, add the matching unsubscribe/untrack on leave.

## New-feature checklist

1. Classify: pure view state / optimistic write / server-gated.
2. Ephemeral truth → a `DoitState` slice (persistent → `localStorage` per `.agents/localstorage.md`).
3. Client-owned element → `data-keep` marker + idempotent `KeepRegistry` applier + a (capture-phase
   for non-bubbling) recorder.
4. Writes → `window.DoitPush`; optimistic ones apply / reconcile / revert and never lie.
5. Server-gated → an up-front `latchButton` / saving hue / held tick at the gesture.
6. Confirm it survives the dead window (rides `DoitPush` or a captured native `phx-*`).
7. Server id parses → `parse_id/1`.
