# PLAN
_Last updated: 2026-05-05_

Human-facing execution dashboard for Do It List. Open this doc first when resuming work.

Use [`CLAUDE.md`](../CLAUDE.md) for working style and engineering rules.
Use milestone docs under `docs/m##-<name>.md` for milestone scope and exit criteria.

## Conventions
- Milestones live as `docs/m##-<name>.md` (e.g. [`docs/m01-baseapp.md`](m01-baseapp.md)).
- New work branches: `claude/<task>`.
- `main` is canonical on GitHub; commits/PRs stay small and reviewable.
- Specs first: a milestone doc exists before its code lands.

## Deferred Decisions
Decisions consciously postponed. Each entry names the trigger that should make us revisit it.

| Decision | Defer until | Rationale |
|---|---|---|
| Branch protection on `main` (require PR, status checks, etc.) | A second contributor joins the repo | Solo dev — protection is friction with no review benefit. |
| GitHub Actions CI (`mix test`, build, etc.) | A second contributor joins the repo | Tests run locally in the dev container; remote CI is overhead until shared review matters. |

## Current
- Active milestone: **M01-BaseApp** — scaffold complete and pushed; treating as done-as-scoped.
- Status: `complete (per m01-baseapp.md acceptance criteria)`
- Next action: scope **M02** (UX Overhaul). Write the spec at `docs/m02-ux-overhaul.md` before code.
- Primary next doc: _TBD — `docs/m02-ux-overhaul.md` (not yet written)._

## Release Target
No public release yet. Owner will not release until at least M02 (UX Overhaul) lands and the app feels presentable.

## Milestones
| Status | ID | Milestone | Short intent | Doc |
|---|---|---|---|---|
| [ ] | M02 | UX Overhaul | Make the app presentable: visual polish, interaction quality, mobile/responsive baseline. Scope TBD. | _TBD_ |

## Completed Milestones
| Status | ID | Milestone | Short intent | Doc |
|---|---|---|---|---|
| [x] | M01 | BaseApp | First working slice: accounts, projects, nested task tree, roll-up progress, project membership, basic activity log, Dockerized. | [`docs/m01-baseapp.md`](m01-baseapp.md) |
