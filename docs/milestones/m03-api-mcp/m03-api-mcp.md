# M03-API-MCP
_Status: Arc 1 complete · Arc 2 scoped · Arc 3 draft stub · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M03 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Expose Do It List's core operations as a programmatic API, and ship an **MCP server** over it so AI agents can drive task trees directly — read and mutate Initiatives, Tasks, Progress, and membership without going through the LiveView UI.

The API is designed **MCP-first**: the MCP server is the API's first concrete consumer, and the surface is shaped to be ergonomic for it (intent-level operations, self-describing schemas, a clean read/mutate split). Designing against a real consumer instead of in the abstract is what keeps the API usable — and a surface an agent can drive cleanly is one a CLI or third-party client inherits well too. The guardrail: the MCP is the API's *first consumer*, not its author — it stays a thin translation layer that consumes the public API over HTTP, never a shortcut into the Elixir contexts.

### North-star use case

An AI agent — **Claude Code first** — manages an Initiative as its working worklist, the way work is tracked today in the `docs/milestones/**` markdown hierarchy (Milestones → Arcs → Worklists → Items → Subitems). The bar: driving a task tree through the MCP/API is **at least as efficient as editing those `.md` files**. The tree mechanics (nesting, order, progress, reparent/reorder) are a natural — arguably better — fit; the doc-only affordances (inline prose, cross-references, git-diff review) map onto the carriers below.

A sharper form of the same case: an agent's own in-flight todo list, normally ephemeral and passively rendered in its coding tool, becomes an interactive Initiative instead — live and two-way. The agent pushes updates as it works (add a task, mark one done, discover and add a subtask); the human can edit or reprioritize from the DoItList UI while the agent is still running, and the agent's next write reflects the current state rather than a stale plan.

## Carrier Mapping

The four carriers — how the markdown docs' content maps onto an Initiative, reusing existing fields rather than building new ones:

| Doc content | Carrier |
|---|---|
| A task's inline narrative (the prose in a doc item) | the task **details** field — plain prose, light markdown at most; **never** a rich-text / document editor |
| Sparse "we decided X because Y" addenda | **comments** — highly limited, concise, only when they add clarity (not noise) |
| What changed, when, by whom (review-as-diff) | **activity rollup** at Initiative / subtree level — `activity_events` already carries both `initiative_id` and `task_id`, so this is read queries + a surface, **no schema change** |
| "see that other task" | **cross-references** — an ID-anchored task→task link, rendered with the task's index label so it never rots on reorder (the index from m02.07 §1.7 is the *label*; the stable ID is the *link*) |

_Per-decision rationale (transport, versioning, auth, rate limiting, bulk, the public/reversible surface, MCP runtime/tool-surface choices) lives in `docs/CHANGELOG.log` as each arc gets scoped and built, not in the arc docs themselves._

## Arcs

**Three arcs.** Arc 1 (HTTP API) and Arc 2 (the MCP server over it — a thin consumer of the public API, never a shortcut into the contexts) are sequenced and deliver the surface; Arc 3 (Documentation & maintenance) publishes the reference and keeps it synced, running last and then continuously. Each arc carries its own tests; testing isn't a separate arc. Per-arc detail lives in the arc files linked below.

| Arc | Doc | Worklists | Status |
|---|---|---|---|
| 1 — HTTP API | [`m03.01-http-api.md`](m03.01-http-api.md) | API foundation · Read surface · Atomic mutation surface · Cross-references · Testing | complete |
| 2 — MCP server | [`m03.02-mcp-server.md`](m03.02-mcp-server.md) | MCP server · Omissions & Corrections · Testing and Verification | scoped |
| 3 — Documentation & maintenance | [`m03.03-documentation+maintenance.md`](m03.03-documentation+maintenance.md) | API reference · MCP reference · Maintenance plan · Testing | draft (stub) |

## Status

Arc 1 (HTTP API) is complete — built, and the operator's manual API pass (WL5.3) is done. Arc 2 (MCP server) is scoped and approved — runtime (a separate stdio process on `anubis_mcp`, the maintained fork of `hermes_mcp`), the tools/resources mapping, and the concurrency approach are all settled; ready to build. Arc 3 (Documentation & maintenance) remains a draft stub, unscoped, though it's already picked up one candidate item from Arc 2's scoping: a Claude Code skill for `apply_operations`.

## Preconditions

- M02 (UX Buildout) lands so the LiveView paths the API will mirror are stable.

## Non-Goals

- Rich-text / document-style task descriptions — the details field stays plain prose.
- OAuth and hosted third-party MCP access — deferred to hosting (M05).
- GraphQL.
- Push / real-time API — M03 is pull-only; no webhooks or push stream (the LiveView's internal PubSub stays internal). Deferred until a consumer needs it.
- Cross-Initiative bulk operations (mirrors the ProductSpec cross-Initiative reorganization deferral).

## Acceptance Criteria

_(TBD once scoped into arcs.)_

## Branch

`M03-api-mcp` (created at scoping time).
