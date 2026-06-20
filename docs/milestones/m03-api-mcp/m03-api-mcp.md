# M03-API-MCP
_Status: stub · Planned start: after M02 (UX Buildout) lands · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M03 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Expose Do It List's core operations as a programmatic API, and ship an **MCP server** over it so AI agents can drive task trees directly — read and mutate Initiatives, Tasks, Progress, and membership without going through the LiveView UI.

The API is designed **MCP-first**: the MCP server is the API's first concrete consumer, and the surface is shaped to be ergonomic for it (intent-level operations, self-describing schemas, a clean read/mutate split). Designing against a real consumer instead of in the abstract is what keeps the API usable — and a surface an agent can drive cleanly is one a CLI or third-party client inherits well too.

## Approach

Two phases, sequenced:

1. **The HTTP API.** A clean, general programmatic surface for the core operations. Get it working smoothly and dogfood it before layering MCP on top.
2. **The MCP server over it.** A thin adapter that consumes the public API — *not* a shortcut into the Elixir contexts. Routing the MCP through the real API is what enforces "design it like an MCP consumes it"; if MCP bypasses the API, the API stops getting validated.

Pull one tiny MCP smoke-client forward into phase 1 to pressure-test the API while it's still cheap to change, rather than building the API blind and discovering ergonomics problems only at MCP time.

**Guardrail:** the MCP is the *first* consumer, not the API's author. Keep the API a general surface; the MCP stays a thin translation layer on top.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Preconditions

- M02 (UX Buildout) lands so the LiveView paths the API will mirror are stable.

## Open Questions

API:
- Transport: REST/JSON, GraphQL, or both?
- Authentication: per-user API tokens (the likely default, since the MCP server authenticates with one), session-cookie reuse, OAuth?
- Versioning policy.
- Rate limiting / quotas.
- Webhook / push API for real-time updates (PubSub-equivalent for external clients)?
- Public vs. private surface — which operations are exposed and which stay LiveView-only?
- Multi-Initiative bulk operations.

MCP:
- Transport: stdio (local) vs streamable-HTTP (remote/hosted — needed if M06 hosts it for Claude Desktop and other remote clients).
- Server runtime: an endpoint in the same Phoenix app vs a separate process; an Elixir MCP library (e.g. Hermes) vs another runtime.
- Tools-vs-resources mapping: which operations are MCP *tools* (actions/mutations) and which are *resources* (read-only context).
- Whether MCP auth == the API token model.

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M03-api-mcp` (created at scoping time).
