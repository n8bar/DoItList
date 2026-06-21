# M03-API-MCP
_Status: scoping — design decisions settled; arcs broken out (draft, pending approval) · Planned start: after M02 (UX Buildout) lands · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M03 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Expose Do It List's core operations as a programmatic API, and ship an **MCP server** over it so AI agents can drive task trees directly — read and mutate Initiatives, Tasks, Progress, and membership without going through the LiveView UI.

The API is designed **MCP-first**: the MCP server is the API's first concrete consumer, and the surface is shaped to be ergonomic for it (intent-level operations, self-describing schemas, a clean read/mutate split). Designing against a real consumer instead of in the abstract is what keeps the API usable — and a surface an agent can drive cleanly is one a CLI or third-party client inherits well too. The guardrail: the MCP is the API's *first consumer*, not its author — it stays a thin translation layer that consumes the public API over HTTP, never a shortcut into the Elixir contexts.

### North-star use case

An AI agent — **Claude Code first** — manages an Initiative as its working worklist, the way work is tracked today in the `docs/milestones/**` markdown hierarchy (Milestones → Arcs → Worklists → Items → Subitems). The bar: driving a task tree through the MCP/API is **at least as efficient as editing those `.md` files**. The tree mechanics (nesting, order, progress, reparent/reorder) are a natural — arguably better — fit; the doc-only affordances (inline prose, cross-references, git-diff review) map onto the carriers below.

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

**Q5 — Pull-only (no push API in M3).** Clients read on demand; no webhooks or push stream. External real-time *watching* of an Initiative is deferred until a consumer needs it — the LiveView's internal PubSub stays internal; exposing it is its own infra. An MCP agent reads the tree when it acts.

**Q6 — Public surface: reversible Initiative work; irreversible stays web-only.** Guiding rule — operations that are **reversible (including soft deletes)** are token-exposed; **irreversible** ones are LiveView-only. **Exposed:** create Initiative, Initiative update, task CRUD / progress / reorg, comments (add / edit / soft-delete-with-tombstone), membership (add / remove / role-change), notifications (read / mark-read), archive / hide, and **move-to-Trash** (soft delete). **LiveView-only:** irreversible ops — permanent delete / empty-Trash, transfer ownership — plus account self-management (register / login / password / email / delete-account, avatars; a work token isn't for managing your account). Exact per-operation list pinned at implementation.

**Q7 — Bulk: one general atomic-operations endpoint.** A single endpoint takes an **ordered list of operations** (create / update / move / reorder / soft-delete), applied **all-or-nothing** in one transaction (`Ecto.Multi`). Adopt the **JSON:API `atomic:operations`** pattern — local ids (`lid`) let a create be referenced later in the same batch (create parent → child under it), with per-op error reporting. This is the "edit many, save once" worklist parity, and the op-list shape suits an LLM agent composing a reshape. One endpoint subsumes fixed batch shapes; a single-item write is just a batch of one. Atomicity is cheap (Multi); the design work is the op-list contract + `lid` resolution + error reporting.

**MCP transport: stdio-first (smooth local path).** DoItList ships a thin **stdio** MCP adapter — a small local process Claude Code launches directly (`claude mcp add …`), authenticated by the per-user token passed via an env var. No hosting, no OAuth: the local Claude Code experience "just works." Remote **streamable-HTTP** (for hosted clients like Claude Desktop / third parties) is deferred to hosting (M06) and is *additive*, not a precondition. Whatever MCP runtime/library we choose **must** support this stdio/local path without forcing a remote/OAuth setup.

## Arcs

**Two arcs, sequenced — Arc 1 then Arc 2.** Arc 1 is the HTTP API; Arc 2 is the MCP server over it (a thin consumer of the public API, never a shortcut into the contexts). Each arc carries its own tests; testing isn't a separate arc. Per-arc detail lives in the arc files linked below.

| Arc | Doc | Worklists | Status |
|---|---|---|---|
| 1 — HTTP API | [`m03.01-http-api.md`](m03.01-http-api.md) | API foundation · Read surface · Atomic mutation surface · Cross-references · Testing | draft |
| 2 — MCP server | [`m03.02-mcp-server.md`](m03.02-mcp-server.md) | MCP server · Testing | draft |

## Status

Scoping in progress. Design decisions are operator-approved; the two arcs are broken out into draft arc files pending approval; the two Arc 2 (MCP) questions are deferred (non-blocking).

## Preconditions

- M02 (UX Buildout) lands so the LiveView paths the API will mirror are stable.

## Non-Goals

- Rich-text / document-style task descriptions — the details field stays plain prose.
- OAuth and hosted third-party MCP access — deferred to hosting (M06).
- GraphQL.
- Cross-Initiative bulk operations (mirrors the ProductSpec cross-Initiative reorganization deferral).

## Acceptance Criteria

_(TBD once scoped into arcs.)_

## Branch

`M03-api-mcp` (created at scoping time).
