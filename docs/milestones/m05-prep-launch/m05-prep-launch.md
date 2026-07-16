# M05-Prep-Launch
_Status: stub · Planned start: after M04 (Final Features) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M05 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Take the feature-complete app from M04 **public**: the launch-readiness work (legal, onboarding, security review) and the go-live work (hosting, deploy, ops). This is the milestone that opens Do It List to the world.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

**Launch readiness**
- **Privacy Policy + Terms of Service.** The legal surface a public account system requires.
- **Data export / delete.** Let a user export their data and delete their account — table stakes for going public.
- **Onboarding & empty states.** First-run experience — the blank-canvas moment, empty Initiatives list, empty Assigned-to-Me, first-Initiative guidance.
- **Landing / marketing page.** A public front door for logged-out visitors, separate from the app shell.
- **Security review.** A pre-public pass — auth, authorization boundaries, the API/MCP surface, rate limiting, dependency audit.

**Go live**
- **Production hosting.** A real hosting story beyond the dev `compose.yaml` — environment config, secrets, TLS, domain (DoItList.app).
- **Deploy pipeline.** Repeatable build + release + rollback.
- **Observability.** Error tracking, uptime monitoring, basic metrics/logging.
- **Backups.** Automated DB backups + a tested restore path.
- **Perf / scale pass.** The data-layer optimization deferred in [`PLAN.md`](../../PLAN.md) (index strategy, `load_tree` scaling, pagination / bulk reads) — now that real client load patterns (the API/MCP and a public audience) exist to key it to.
- **MCP goes public.** The stdio adapter (M03 Arc 2) stays local-only by construction — it needs `docker exec` access to whatever machine runs it, so it doesn't reach a hosted instance. Decided: MCP goes public at launch, not staying a local/private connector. Wire `anubis_mcp`'s Streamable-HTTP/SSE transport (stdio-only today) so any MCP client can reach the hosted instance with a personal API token — the same Bearer-token model Arc 1 already built, no new auth path. OAuth and any official third-party-connector-UI integration (e.g. a vendor's own "Bring Your Own MCP" button) are a separate, still-open question, not required for this. Package the adapter as a mix release for this deployment — one long-lived server, boot cost paid at deploy; the per-session ~15s BEAM boot (and its mix/compile-check layer) goes away with the stdio process-per-client model.

## Preconditions

- M04 (Final Features) lands — the product is feature-complete for launch; this milestone adds no new functionality, only readiness and infrastructure.
- Email infrastructure (M04) is live — public registration, verification, and password reset all depend on it.

## Open Questions

- Hosting target (managed PaaS vs VPS vs container platform) and what it implies for deploy and backups.
- CI/CD: this is the trigger named in [`PLAN.md`](../../PLAN.md)'s Deferred Decisions for GitHub Actions and branch protection — revisit both here.
- Legal review depth for Privacy Policy / ToS (templated vs reviewed).

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M05-prep-launch` (created at scoping time).
