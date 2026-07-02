# PLAN
_Last updated: 2026-07-02_

Human-facing execution dashboard for Do It List. Open this doc first when resuming work.

For doc structure, the action-list hierarchy, and conventions (numbering, layout, deadlines), see [`README.md`](README.md).
For working style, engineering rules, branching, and repo workflow, see [`../CLAUDE.md`](../CLAUDE.md).
For product behavior and invariants, see [`ProductSpec.md`](ProductSpec.md).

## Deferred Decisions
Decisions consciously postponed. Each entry names the trigger that should make us revisit it.

| Decision | Defer until | Rationale |
|---|---|---|
| Branch protection on `main` (require PR, status checks, etc.) | A second contributor joins the repo | Solo dev — protection is friction with no review benefit. |
| GitHub Actions CI (`mix test`, build, etc.) | A second contributor joins the repo | Tests run locally in the dev container; remote CI is overhead until shared review matters. |
| JS test framework (vs. the homemade `assert()` in `rollup_test.html`, m03.02) | The JS test surface grows meaningfully beyond m03.02's rollup/cascade cases | Current surface is small and fixed — a framework's grouping/diffing doesn't pay for itself yet. Must be a zero-install vendored file either way; this project has no Node/npm to install one via. |

## Release Target
No public release yet. The app won't open to the public before **M05 (Prep and Launch)** — the milestone that owns going public. M02 (UX Buildout) remains the floor for the app feeling presentable. M06 and M07 are deliberately sequenced *after* launch to keep the path there short.

## Milestones
| Status | ID | Milestone | Short intent | Target | Doc |
|---|---|---|---|---|---|
| [ ] | M02 | UX Buildout | Bring M01 to UX_GUARDRAILS + targeted design refinements so the app feels presentable. Arc scope and status live in the linked milestone doc's Arcs table. | 2026-05-29 | [`milestones/m02-ux-buildout/m02-ux-buildout.md`](milestones/m02-ux-buildout/m02-ux-buildout.md) |
| [ ] | M03 | API & MCP | Programmatic API for Initiatives / Tasks / membership, designed MCP-first, plus an MCP server over it so agents can drive task trees. Arc scope and status live in the linked milestone doc's Arcs table. | TBD | [`milestones/m03-api-mcp/m03-api-mcp.md`](milestones/m03-api-mcp/m03-api-mcp.md) |
| [ ] | M04 | Final Features | Last product features before public — email infra & invites, recovery codes, TOTP, donation. Stub. | TBD | [`milestones/m04-final-features/m04-final-features.md`](milestones/m04-final-features/m04-final-features.md) |
| [ ] | M05 | Prep and Launch | Launch readiness (legal, onboarding, security) + go-live (hosting, deploy, observability, backups). Opens the app to the public. Stub. | TBD | [`milestones/m05-prep-launch/m05-prep-launch.md`](milestones/m05-prep-launch/m05-prep-launch.md) |
| [ ] | M06 | Roles & Avatar | Post-launch: admin role, taskmaster (task-scoped full-control role), avatar upload. Stub. | TBD | [`milestones/m06-roles-avatar/m06-roles-avatar.md`](milestones/m06-roles-avatar/m06-roles-avatar.md) |
| [ ] | M07 | Templates & Reuse | Post-launch: reusable task trees — Initiative templates, duplicate a non-owned Initiative, trash↔duplicate interplay. Stub. | TBD | [`milestones/m07-templates-reuse/m07-templates-reuse.md`](milestones/m07-templates-reuse/m07-templates-reuse.md) |

## Completed Milestones
| Status | ID | Milestone | Short intent | Completed | Doc |
|---|---|---|---|---|---|
| [x] | M01 | BaseApp | First working slice: accounts, Initiatives, nested task tree, roll-up progress, Initiative membership, basic activity log, Dockerized. | 2026-05-05 | [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) |
