# PLAN
_Last updated: 2026-05-06_

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

## Current
- Active milestone: **M02-UX-Overhaul** — scoped 2026-05-06; target 2026-05-22.
- Status: `scoped, not yet started`
- Next action: Land m02.02.01 (theme toggle) so the audit in m02.01.01 can cover both light and dark modes.
- Primary next doc: [`milestones/m02-ux-overhaul/m02-ux-overhaul.md`](milestones/m02-ux-overhaul/m02-ux-overhaul.md).
- Branch: `M02-ux-overhaul`.

## Release Target
No public release yet. Owner will not release until at least M02 (UX Overhaul) lands and the app feels presentable.

## Milestones
| Status | ID | Milestone | Short intent | Target | Doc |
|---|---|---|---|---|---|
| [ ] | M02 | UX Overhaul | Bring M01 to UX_GUARDRAILS + design refinements. Arc 1 (bring-to-spec) complete; Arc 2 (design refinements) complete (27 items); Arc 3 (drag-and-drop) scoped; Arc 4 (Wide-Width Layout — responsive groundwork at xl/2xl, then a unified triple-pane at ultrawide where the left rail IS the Initiatives index plus a cross-Initiative people pane; click or drag people onto Initiatives to add them) drafted. Per-arc detail in linked arc files. | 2026-05-22 | [`milestones/m02-ux-overhaul/m02-ux-overhaul.md`](milestones/m02-ux-overhaul/m02-ux-overhaul.md) |
| [ ] | M03 | API | Programmatic API for Initiatives / Tasks / membership so external clients can integrate. Stub only — transport, auth, versioning, push-API surface all TBD. | TBD | [`milestones/m03-api/m03-api.md`](milestones/m03-api/m03-api.md) |

## Completed Milestones
| Status | ID | Milestone | Short intent | Completed | Doc |
|---|---|---|---|---|---|
| [x] | M01 | BaseApp | First working slice: accounts, Initiatives, nested task tree, roll-up progress, Initiative membership, basic activity log, Dockerized. | 2026-05-05 | [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) |
