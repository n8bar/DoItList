# PLAN
_Last updated: 2026-06-09_

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
| Data-layer optimization beyond hot-path fixes (index strategy, `load_tree` scaling, pagination / bulk reads) | M03 (API) scoping — real client load patterns exist | Hot N+1s fixed in M02 Arc 3; the rest has no trigger at current single-user scale, and an API is what will create one. |

## Release Target
No public release yet. Operator will not release until at least M02 (UX Buildout) lands and the app feels presentable.

## Milestones
| Status | ID | Milestone | Short intent | Target | Doc |
|---|---|---|---|---|---|
| [ ] | M02 | UX Buildout | Bring M01 to UX_GUARDRAILS + targeted design refinements so the app feels presentable. Arc scope and status live in the linked milestone doc's Arcs table. | 2026-05-29 | [`milestones/m02-ux-buildout/m02-ux-buildout.md`](milestones/m02-ux-buildout/m02-ux-buildout.md) |
| [ ] | M03 | API | Programmatic API for Initiatives / Tasks / membership so external clients can integrate. Stub only — transport, auth, versioning, push-API surface all TBD. | TBD | [`milestones/m03-api/m03-api.md`](milestones/m03-api/m03-api.md) |

## Completed Milestones
| Status | ID | Milestone | Short intent | Completed | Doc |
|---|---|---|---|---|---|
| [x] | M01 | BaseApp | First working slice: accounts, Initiatives, nested task tree, roll-up progress, Initiative membership, basic activity log, Dockerized. | 2026-05-05 | [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) |
