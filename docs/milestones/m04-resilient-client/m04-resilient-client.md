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
