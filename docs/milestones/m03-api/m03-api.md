# M03-API
_Status: stub · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M03 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Expose Do It List's core operations as a programmatic API so external integrations (CLIs, automations, third-party clients) can read and mutate Initiatives, Tasks, Progress, and membership without going through the LiveView UI.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Preconditions

- M02 (UX Buildout) lands so the LiveView paths the API will mirror are stable.

## Open Questions

- Transport: REST/JSON, GraphQL, or both?
- Authentication: session-cookie reuse, API tokens per user, OAuth, something else?
- Versioning policy.
- Rate limiting / quotas.
- Webhook / push API for real-time updates (PubSub-equivalent for external clients)?
- Public vs. private surface — which operations are exposed and which stay LiveView-only?
- Multi-Initiative bulk operations.

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M03-api` (created at scoping time).
