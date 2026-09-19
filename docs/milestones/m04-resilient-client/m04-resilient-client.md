# M04-Resilient-Client
_Status: Milestone and arc scope approved 2026-09-15 · Target: ~2026-Q4_

Product behavior comes from [`ProductSpec.md`](../../ProductSpec.md) and [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md).

## Goal

Keep Do It List immediate, dependable, and efficient through latency, disconnection, concurrent use, and large Initiatives.

## Accomplishes

1. Client-owned product interface.
2. Dependable collaboration and disruption recovery.
3. Resource-efficient concurrent-user scaling.
4. Responsive large-Initiative trees.
5. Tree Tools and selected view controls.
6. Measured capacity and automated regression gates.

## Included

1. Replace interactive LiveView pages with browser-rendered views using the existing server operations.
2. Persist last-known Initiative data and pending writes locally until acknowledgement or logout.
3. Implement ProductSpec §§6.1, 6.2.6, and 11 across latency, reconnection, concurrent edits, and rejected writes.
4. Finish Tree Tools; add task-row element visibility, completed-Task filtering, and Initiative-description display controls.
5. Make navigation controls unmistakable buttons and satisfy `UX_GUARDRAILS.md`.
6. Establish reproducible, resource-capped tests for many rooms, hot rooms, reconnect storms, long idle periods, and large Initiatives.

## Arcs

All seven arc documents are approved.

| Arc | Focus | Proposed dependency |
|---|---|---|
| [1 — Client runtime](m04.01-client-runtime.md) | Browser foundation | Complete 2026-09-16 |
| [2 — Client-owned tree](m04.02-client-owned-tree.md) | Tree migration | Complete 2026-09-19 |
| [3 — Live sync & recovery](m04.03-live-sync+recovery.md) | Collaboration and disruption | Complete 2026-09-19 |
| [4 — Concurrent-user efficiency](m04.04-concurrent-user-efficiency.md) | Server capacity | Arc 3 |
| [5 — Large-Initiative performance](m04.05-large-initiative-performance.md) | Browser capacity | Arc 2 |
| [6 — Tree Tools & view controls](m04.06-tree-tools+view-controls.md) | Included tree/view features | Arcs 2 and 5 |
| [7 — Product cutover & hardening](m04.07-product-cutover+hardening.md) | Remaining views and final proof | Arcs 3–6 |

## Preconditions

- The existing operations endpoint, record versions, idempotency keys, and transaction-aware broadcasts are the starting substrate.
- The M02 UX baseline remains the parity floor throughout migration, especially `UX_GUARDRAILS.md` §6 and §7.

## Excluded

1. Character-by-character co-editing, automatic merging of independently edited copies, editing locks, and blocking conflict prompts.
2. Offline-first operation, synchronization after the browser closes, and cross-device pending-write queues.
3. Cross-Initiative task moves.
4. [`BACKLOG.md`](../../BACKLOG.md) features not named under Included.
5. Unlimited-scale claims; M04 reports measured capacity on declared hardware.

## Complete When

All Included work meets ProductSpec §§6 and 11, `UX_GUARDRAILS.md`, and every arc's Exit.

## Branch

`M04-resilient-client`
