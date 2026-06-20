# M03-API-MCP
_Status: scoping in progress — design decisions drafted below (pending operator approval); arcs TBD · Planned start: after M02 (UX Buildout) lands · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M03 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Expose Do It List's core operations as a programmatic API, and ship an **MCP server** over it so AI agents can drive task trees directly — read and mutate Initiatives, Tasks, Progress, and membership without going through the LiveView UI.

The API is designed **MCP-first**: the MCP server is the API's first concrete consumer, and the surface is shaped to be ergonomic for it (intent-level operations, self-describing schemas, a clean read/mutate split). Designing against a real consumer instead of in the abstract is what keeps the API usable — and a surface an agent can drive cleanly is one a CLI or third-party client inherits well too.

### North-star use case

An AI agent — **Claude Code first** — manages an Initiative as its working worklist, the way work is tracked today in the `docs/milestones/**` markdown hierarchy (Milestones → Arcs → Worklists → Items → Subitems). The bar: driving a task tree through the MCP/API is **at least as efficient as editing those `.md` files**. The tree mechanics (nesting, order, progress, reparent/reorder) are a natural — arguably better — fit; the doc-only affordances (inline prose, cross-references, git-diff review) map onto the carriers below.

## Approach

Two phases, sequenced:

1. **The HTTP API.** A clean, general programmatic surface for the core operations. Get it working smoothly and exercise it against a real consumer before layering MCP on top.
2. **The MCP server over it.** A thin adapter that consumes the public API — *not* a shortcut into the Elixir contexts. Routing the MCP through the real API is what enforces "design it like an MCP consumes it"; if MCP bypasses the API, the API stops getting validated.

Pull one tiny MCP smoke-client forward into phase 1 to pressure-test the API while it's still cheap to change, rather than building the API blind and discovering ergonomics problems only at MCP time.

**Guardrail:** the MCP is the *first* consumer, not the API's author. Keep the API a general surface; the MCP stays a thin translation layer on top.

## Design Decisions

**Scope: structural-first.** M03 delivers the structural surface — tree CRUD (create / read / update / move / reorder / reparent), roll-up progress, membership — plus the three supporting surfaces below. The prose/narrative layer rides existing fields; no new editor.

**The four carriers** — how the markdown docs' content maps onto an Initiative:

| Doc content | Carrier |
|---|---|
| A task's inline narrative (the prose in a doc item) | the task **details** field — plain prose, light markdown at most; **never** a rich-text / document editor |
| Sparse "we decided X because Y" addenda | **comments** — highly limited, concise, only when they add clarity (not noise) |
| What changed, when, by whom (review-as-diff) | **activity rollup** at Initiative / subtree level — `activity_events` already carries both `initiative_id` and `task_id`, so this is read queries + a surface, **no schema change** |
| "see that other task" | **cross-references** — an ID-anchored task→task link, rendered with the task's index label so it never rots on reorder (the index from m02.07 §1.7 is the *label*; the stable ID is the *link*) |

**Q1 — API transport: REST / JSON.** Resource-and-verb endpoints over plain JSON; a whole-tree read returns the nested Initiative in one response (already assembled server-side for the LiveView); targeted `PATCH` / `POST` for surgical edits. GraphQL rejected — its field-selection flexibility isn't what an MCP/CLI needs, and it adds a schema/resolver layer for no consumer benefit.

**Q3 — Versioning: path versioning.** The version lives in the URL (`/api/v1/…`); v1 and v2 can run side-by-side during a migration. Within a version, changes stay additive (add fields, don't remove/rename) — a true breaking change earns a new path. Cheap now (the MCP is the only consumer, updated in lockstep) and clean later when external clients exist.

**Q2 — Authentication: per-user API tokens.** A user mints a token in account settings; clients send it as `Authorization: Bearer <token>` and thereby act as that user, inheriting their `owner` / `editor` / `viewer` roles unchanged — the token adds *identification*, not a new authorization system. Revocable. Whether to upgrade to **scoped / fine-grained tokens** (per-Initiative or read-only) is a refinement to settle at implementation time — start broad-and-revocable, tighten only if wanted. OAuth (third-party-acting-on-your-behalf) is deferred and can later layer onto the same token-checking core.

**Q4 — Rate limiting: a simple per-token limit, built in M03.** A fixed-window / token-bucket cap (N requests per window, per token), enforced at the token layer — cheap insurance against a runaway agent loop or retry-storm. Exact limits are tunable at implementation. Tiered / per-plan quotas stay out (no plans yet).

**MCP transport: stdio-first (smooth local path).** DoItList ships a thin **stdio** MCP adapter — a small local process Claude Code launches directly (`claude mcp add …`), authenticated by the per-user token passed via an env var. No hosting, no OAuth: the local Claude Code experience "just works." Remote **streamable-HTTP** (for hosted clients like Claude Desktop / third parties) is deferred to hosting (M06) and is *additive*, not a precondition. Whatever MCP runtime/library we choose **must** support this stdio/local path without forcing a remote/OAuth setup.

## Status

Scoping in progress. Design decisions above are drafted pending operator approval; remaining open questions below; not yet broken into arcs.

## Preconditions

- M02 (UX Buildout) lands so the LiveView paths the API will mirror are stable.

## Open Questions

API:
- Webhook / push API for real-time updates (PubSub-equivalent for external clients)?
- Public vs. private surface — the exact operation list exposed (vs. LiveView-only).
- Bulk operations *within* an Initiative (batch create / move / update) to match "edit many doc lines, save once."

MCP:
- Server runtime/library: an endpoint in the same Phoenix app vs. a separate process; an Elixir MCP library (e.g. Hermes) vs. another runtime — gated by the stdio/local-smoothness requirement above.
- Tools-vs-resources mapping: which operations are MCP *tools* (actions/mutations) and which are *resources* (read-only context — e.g. the activity rollup).

## Non-Goals

- Rich-text / document-style task descriptions — the details field stays plain prose.
- OAuth and hosted third-party MCP access — deferred to hosting (M06).
- GraphQL.
- Cross-Initiative bulk operations (mirrors the ProductSpec cross-Initiative reorganization deferral).

## Acceptance Criteria

_(TBD once scoped into arcs.)_

## Branch

`M03-api-mcp` (created at scoping time).
