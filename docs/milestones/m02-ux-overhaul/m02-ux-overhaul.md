# M02-UX-Overhaul
_Status: scoped · Target: 2026-05-15_

> Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). This milestone doc owns M02 scope and acceptance criteria.

## Goal

Bring the M01 baseline app into alignment with the UX guardrails and apply a set of targeted design refinements so the product feels presentable.

This is the milestone that earns the first public release.

## Arcs

### m02.01 — UX Guardrails Audit & Alignment

Pass over current code against the universal baseline; address gaps; record project-specific UX rules surfaced during M02.

1. [ ] **m02.01.01** — Audit the running app against every rule in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md) § Universal Baseline. Cover desktop and mobile widths; cover both light and dark modes (after m02.02.01 lands). Log each gap as a separate `F#NN` entry in [`FINDINGS.md`](../../FINDINGS.md) — observation only, no fix detail.
2. [ ] **m02.01.02** — Add the project-specific UX rules surfaced by M02 to [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md) § Project-Specific Additions:
   - **Default-hidden attributes.** Task attributes render only when set to a non-default value. Always-shown: title, progress, completion checkbox, inline description (when present). Default-hidden: weight (≠ 1), priority (≠ normal), assignee (set).
   - **No layout shift on collapse/expand or theme toggle.** Reserve space; transitions animate in place.
3. [ ] **m02.01.03** — Promote and resolve findings logged in m02.01.01. As findings are triaged, link them here as a sub-checklist (`F#NN — short title`); flip each to `promoted` in FINDINGS.md when scheduled and `fixed` when resolved. If any single fix is large enough to warrant a breakout, decompress to a Worklist (`m02.01.03-<slug>.md`) per the convention in [`PLAN.md`](../../PLAN.md) § Conventions.

### m02.02 — Design Refinements

Discrete UI changes scoped explicitly with the owner.

1. [ ] **m02.02.01** — **Theme toggle.** Three-state control (System / Light / Dark) modeled on CryptoZing's. System is the default selection on first load (follows `prefers-color-scheme`); user choice persists per-user, server-side, so it follows them across devices. Both light and dark must look polished — neither is a graceful fallback. Place the toggle in the app chrome (header or user menu). _Land first: m02.01.01 needs both modes available to audit them._
2. [ ] **m02.02.02** — **Full-width progress underbar.** Replace the current task-progress indicator with a thin colored bar pinned to the bottom edge of each task row, spanning the full row width less a small horizontal margin. Same treatment at every level of the tree. Drive from a CSS custom property (`--progress`) so updates don't shift layout.
3. [ ] **m02.02.03** — **Completion checkbox left of task name.** Adds a checkbox immediately before the title. On a leaf task, toggling sets progress 0 ↔ 100. On a parent task, checking opens a confirmation dialog ("Mark all child tasks completed?"); on confirm, cascade 100% to every descendant; on cancel, no-op. Use the same dialog pattern for any future destructive/irreversible confirmations.
4. [ ] **m02.02.04** — **Collapsible children.** Tasks with children show an expand/collapse signifier — visually distinct from the add-subtask signifier (see m02.02.07). Default state on first view: expanded. Per-task collapsed state persists in `localStorage` only (not server). Collapsed branches still contribute to roll-up; only the visual children are hidden.
5. [ ] **m02.02.05** — **Task row layout.** Single-line row, in order: completion checkbox · title · custom-attribute chips (only when non-default per m02.01.02) · ` — ` (em dash with surrounding spaces) · description in a faded font. Description fills remaining horizontal space with `white-space: nowrap; overflow: hidden; text-overflow: ellipsis`. On very narrow viewports the description hides entirely; otherwise it consumes whatever width remains. Description is read-only inline — editing happens in the task detail view. Clicking anywhere on the row outside interactive sub-elements opens detail.
6. [ ] **m02.02.06** — **Project-level progress underbar.** A project may contain multiple Lists (root tasks), so surface an aggregate project-progress bar in the project header using the same underbar treatment as m02.02.02. Aggregate is the equal-weighted average of root-task roll-up progress (custom weights at root level are not honored at the project level — the project header is informational, not itself a task).
7. [ ] **m02.02.07** — **Add-subtask signifier rework.** Current `+` is unclear and conflicts visually with an expand-style affordance. (Per Jakob Nielsen, _signifier_ is the correct term — "a perceivable indicator that communicates appropriate behavior to a user.") Replace with a clearer add-subtask affordance distinct from the collapse/expand control introduced in m02.02.04. Pick one direction: a labeled "+ Subtask" pill on row hover/focus, an indented placeholder row at the end of a parent's children, or a dedicated icon (e.g. plus-with-branch). Whichever direction wins must survive keyboard-only use and meet the 44×44 px touch-target rule.
8. [ ] **m02.02.08** — **Remove `status` from task UI.** Hide the task `status` field from every UI surface: task detail, task row, filters, activity log entries. Schema column stays — no migration in M02 — so we can revisit later as a more complete idea. Activity-log entries that previously named status changes are dropped from the log going forward; existing rows in the log can stay in place (they don't surface anywhere now).

## Non-Goals

- Drag-and-drop reordering (still deferred from M01).
- Status field redesign — explicitly removed from UI; revisit later as a fuller idea.
- Notifications, attachments, board/calendar views, public sharing, AI features — unchanged from M01 non-goals.
- Schema migrations beyond what individual items require (none, in current scope).

## Acceptance Criteria

- All eight m02.02 items shipped and visible in the running app.
- m02.01.01 audit complete; every finding logged as `F#NN` and either marked `fixed` (with link to the resolving change) or explicitly `deferred` (with reason).
- Project-specific UX rules added to [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md).
- Both light and dark modes pass a visual review of every primary screen.
- No regressions in M01 acceptance criteria.

## Implementation Notes

- **Theme persistence.** Persist user choice on the `users` table (or a `user_preferences` join — pick whichever fits the schema with less churn). System mode means "follow `prefers-color-scheme`" — store no override, not a literal `"system"` string, unless a column-default makes the latter cleaner.
- **Underbar implementation.** Prefer CSS-only driven by a `--progress` custom property; avoid layout-shifting on update.
- **Collapse-state key.** Key by `(project_id, task_id)` in `localStorage`; expire entries when their task is deleted.
- **Narrow-viewport breakpoint.** Pick one Tailwind breakpoint for "very narrow" (likely `sm:` boundary) and reuse it consistently for description-hide and any other narrow-mode behavior.
- **Audit pairing.** m02.02.01 (theme toggle) lands before m02.01.01 (audit) so audit covers both modes in a single pass.

## Branch

`M02-ux-overhaul`
