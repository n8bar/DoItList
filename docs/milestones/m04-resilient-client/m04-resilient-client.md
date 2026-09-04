# M04-Resilient-Client
_Status: stub · Planned start: after M03 (API & MCP) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M04 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

**The client survives server disturbance.** Today the server renders everything, so any wobble — a deploy, a slow commit, a crashing mount — freezes the whole page, and a crash loop strobes "Connecting…" indefinitely. This milestone inverts the roles on the tree workspace: the client owns the model and the rendering; the server owns durability and ordering. Later milestones then build tree-surface features (M05's Trash among them) on the new foundation instead of paying for them twice.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

- **Client-owned tree workspace.** The browser holds the Initiative's tree model and renders from local state. User actions apply to the local model instantly, queue as task-level operations, and sync through the existing ordered/atomic operations surface (m03.01) — the server sequences and broadcasts; it stops rendering this surface. Task-level ops with simple conflict rules — no character-level OT, no CRDTs; concurrent edits to the same field of the same task are rare and coarse.
- **Reconnect budget + degraded mode.** During disconnect or reconnect the last-known tree stays visible and readable — never a frozen page. Repeated failed mounts land on an explicit error state with a retry, never an unbounded reconnect loop.
- **Resync semantics.** Reconnect = fetch snapshot, replay the outbound queue, converge. Defined once, tested against wobble, deploy, and crash-loop scenarios.
- **§6 round-trip sweep.** The remaining server-gated interactions on the tree surface come under the same optimistic bar as the rest — swept as part of the move rather than patched one by one.

Low-frequency surfaces (account, auth, import approvals, chrome) stay server-rendered — the inversion is scoped to the tree workspace.

## Carried over from M03

Two tree-workspace bugs handed here from m03.04 so the fix is written once, on the client-owned tree:

- **Move-confirm false positive: emptying a branch reads as completing it.** Promoting the only child of a branch raised "will mark previously incomplete task(s) as complete" naming the parent, in an Initiative with zero complete tasks: the client flip predictor's source rule is vacuously true when a move removes ALL of an ancestor's leaves, while the authoritative math makes an emptied branch its own leaf (open, manual 0 → 0, no flip). The server preview classifies correctly. Expected: no confirm, the move lands, the emptied parent reads 0% and stays open.
- **Tail drop-zone loses its bottom seat.** Dropping a task on a branch's tail drop-zone lands the row visually below the strip, so the strip stops being the branch's bottom edge. Expected: the strip stays the branch's last element through the drop and the server echo.

## Preconditions

- M03 (API & MCP) lands — the operations endpoint is the sync backbone and must be stable.

## Open Questions

- Rendering stack for the client-owned pane (build up from the existing hooks/JS vs adopt a framework — weighed against the no-Node/no-npm constraint).
- Whether the outbound queue persists locally (survive a tab crash) in this milestone or stays in-memory.

## Non-Goals

- Character-level collaborative text editing (OT/CRDT).
- Offline-first as a product feature — resilience here means surviving disturbance, not working disconnected for days.

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M04-resilient-client` (created at scoping time).
