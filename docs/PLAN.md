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
- Active milestone: **M02-UX-Overhaul** — scoped 2026-05-06; target 2026-05-15.
- Status: `scoped, not yet started`
- Next action: Land m02.02.01 (theme toggle) so the audit in m02.01.01 can cover both light and dark modes.
- Primary next doc: [`milestones/m02-ux-overhaul/m02-ux-overhaul.md`](milestones/m02-ux-overhaul/m02-ux-overhaul.md).
- Branch: `M02-ux-overhaul`.

## Release Target
No public release yet. Owner will not release until at least M02 (UX Overhaul) lands and the app feels presentable.

## Milestones
| Status | ID | Milestone | Short intent | Target | Doc |
|---|---|---|---|---|---|
| [ ] | M02 | UX Overhaul | Bring M01 to UX_GUARDRAILS + twenty-six design refinements (original ten + six casual-test follow-ons + ten more from continued review: fixed-height layout w/ main-scrollable content, nav reorder, add-button borders + bold green, branch icon w/ leaves, click-to-deselect, password eyeball, drop weight from new-task line, sibling split-button, own-first index + role badge). | 2026-05-15 | [`milestones/m02-ux-overhaul/m02-ux-overhaul.md`](milestones/m02-ux-overhaul/m02-ux-overhaul.md) |

## Completed Milestones
| Status | ID | Milestone | Short intent | Completed | Doc |
|---|---|---|---|---|---|
| [x] | M01 | BaseApp | First working slice: accounts, Initiatives, nested task tree, roll-up progress, Initiative membership, basic activity log, Dockerized. | 2026-05-05 | [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) |
