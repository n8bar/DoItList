# PLAN
_Last updated: 2026-05-05_

Human-facing execution dashboard for Do It List. Open this doc first when resuming work.

Use [`CLAUDE.md`](../CLAUDE.md) for working style and engineering rules.
Use [`ProductSpec.md`](ProductSpec.md) for product behavior and invariants.
Use milestone docs under `docs/m##-<name>.md` for milestone scope and exit criteria.

## Doc Roles
Two top-level docs sit at level 1 of the hierarchy, split by purpose:
- **PLAN.md** — master *action* list. Milestones, status, deferred decisions, what's next. *How we get there.*
- **[`ProductSpec.md`](ProductSpec.md)** — master *spec*. Vocabulary, principles, behaviors, invariants. *What "there" means.*

[`CLAUDE.md`](../CLAUDE.md) sits above the split as the always-loaded primer — not a spec, not an action list, just whatever should be in context regardless of what we're working on.

Below level 1:
- **Milestone docs** (`docs/m##-<name>.md`) — per-milestone scope and acceptance criteria.
- **Worklist docs** *(future, optional)* — task-level action breakdowns under a milestone, when one gets large enough to warrant them.
- **Subsystem specs** *(future, optional)* — focused specs for behaviors that outgrow their milestone doc.

**Stay at your altitude.** A higher-level doc summarizes intent, names the thing, and links down. It does not catalog the same level of detail as its child docs. If PLAN.md or ProductSpec.md starts listing edge cases or per-task steps, that content belongs lower.

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
