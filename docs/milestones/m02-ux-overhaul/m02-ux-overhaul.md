# M02-UX-Overhaul
_Status: scoped · Target: 2026-05-15_

> Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). This milestone doc owns M02 scope and acceptance criteria.

## Goal

Bring the M01 baseline app up to the UX guardrails and apply a set of targeted design refinements so the product feels presentable.

This is the milestone that earns the first public release.

## Preconditions

- The vocabulary rename of Project → Initiative (two chore branches on 2026-05-07; see [`CHANGELOG.log`](../../CHANGELOG.log)) is complete. M02 items reference the final vocabulary.

## Arcs

### 1 — Bring M01 to spec

Add the project-specific UX rules and close the gaps in the M01 baseline that Arc 2 won't already address. Arc 2's own items are responsible for following the spec in their own implementations — Arc 1 doesn't audit them.

1. [x] Add the following project-specific UX rules to [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md) § Project-Specific Additions:
   - **Default-hidden attributes.** Task attributes render only when set to a non-default value. Always-shown: title, progress, completion checkbox, inline description (when present). Default-hidden: weight (≠ 1), priority (≠ normal), assignee (set).
   - **No layout shift on collapse/expand or theme toggle.** Reserve space; transitions animate in place.
2. [x] Audit the M01 baseline against [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md) § Universal Baseline; fix any gaps **not already addressed by Arc 2 items**. Use `fix/<slug>` branches per the working-style rule or roll fixes into Arc 1 commits — your call per fix.

### 2 — Design Refinements

Discrete UI changes scoped explicitly with the owner. Each Arc 2 item is responsible for satisfying the universal baseline in its own implementation; no separate verification step.

1. [x] **Theme toggle.** Three-state control (System / Light / Dark) modeled on CryptoZing's. System is the default selection on first load (follows `prefers-color-scheme`); user choice persists per-user, server-side, so it follows them across devices. Both light and dark must look polished — neither is a graceful fallback. Place the toggle in the app chrome (header or user menu). _Initial pass: toggle + persistence + dark variants on body/header/initiative-index/initiative-show/home. Polish (subtle states, edge contrast, etc.) can land via `fix/` branches per the working-style rule as gaps surface in dogfooding._
2. [x] **Edit Initiative metadata via right-rail panel.** Add a static pencil-icon signifier next to the Initiative h1 (always visible — no hover dependency; mobile-friendly). Clicking the pencil or the h1 itself flips the right-rail panel to "Initiative details" with editable name and description fields. The panel reuses the same slot, close/save/keyboard patterns, and component as Task details — only the header text and field schema swap based on selection. Currently editable: name, description. (Future: icon, color, defaults, etc.)
3. [x] **Full-width progress underbar.** Replace the current task-progress indicator with a thin colored bar pinned to the bottom edge of each task row, spanning the full row width less a small horizontal margin. Same treatment at every level of the tree. Drive from a CSS custom property (`--progress`) so updates don't shift layout.
4. [x] **Completion checkbox left of task name.** Adds a checkbox immediately before the title. On a leaf task, toggling sets progress 0 ↔ 100. On a parent task, checking opens a confirmation dialog ("Mark all child tasks completed?"); on confirm, cascade 100% to every descendant; on cancel, no-op. Use the same dialog pattern for any future destructive/irreversible confirmations.
5. [x] **Collapsible children.** Tasks with children show an expand/collapse signifier — visually distinct from the add-subtask signifier (item 8). Default state on first view: expanded. Per-task collapsed state persists in `localStorage` only (not server). Collapsed branches still contribute to roll-up; only the visual children are hidden.
6. [x] **Task row layout.** Single-line row, in order: completion checkbox · botanical icon (item 10) · title · custom-attribute chips (only when non-default per Arc 1) · ` — ` (em dash with surrounding spaces) · description in a faded font. Description fills remaining horizontal space with `white-space: nowrap; overflow: hidden; text-overflow: ellipsis`. On very narrow viewports the description hides entirely; otherwise it consumes whatever width remains. Description is read-only inline — editing happens in the task detail view. Clicking anywhere on the row outside interactive sub-elements opens detail.
7. [x] **Initiative-level progress underbar.** An Initiative may contain multiple Lists (root tasks), so surface an aggregate progress bar in the Initiative header using the same underbar treatment as the per-task bar. Aggregate is the equal-weighted average of root-task roll-up progress (custom weights at root level are not honored at the Initiative level — the Initiative header is informational, not itself a task).
8. [x] **Add-subtask signifier rework.** Current `+` is unclear and conflicts visually with an expand-style affordance. (Per Jakob Nielsen, _signifier_ is the correct term — "a perceivable indicator that communicates appropriate behavior to a user.") Replace with a clearer add-subtask affordance distinct from the collapse/expand control in item 5. Pick one direction: a labeled "+ Subtask" pill on row hover/focus, an indented placeholder row at the end of a parent's children, or a dedicated icon (e.g. plus-with-branch). Whichever direction wins must survive keyboard-only use and meet the 44×44 px touch-target rule.
9. [x] **Remove `status` from task UI.** Hide the task `status` field from every UI surface: task detail, task row, filters, activity log entries. Schema column stays — no migration in M02 — so we can revisit later as a more complete idea. Activity-log entries that previously named status changes are dropped from the log going forward; existing rows in the log can stay in place (they don't surface anywhere now).
10. [x] **Botanical icon set.** Apply the visual metaphor at the icon layer:
    - **Initiative** (in nav, page header, and the Initiative-list cards): Lucide `trees` (small grove of multiple trees).
    - **List** (root task): Lucide `tree-deciduous` or `tree-pine`.
    - **Task with children** (parent task): branch icon (custom SVG or closest Lucide; verify availability at implementation time).
    - **Leaf task** (no children): Lucide `leaf`.

    Heroicons doesn't ship most of these — import Lucide (MIT, similar line-style aesthetic) alongside Heroicons. Pairs with item 6 (row layout); land before or with it so the row composes correctly.
11. [x] **Inline-edit Initiative title + Details ellipses.** Refinement of item 2. Two affordances on the Initiative h1: clicking the h1 itself triggers **inline editing** of the title in place — the h1 turns into a text input, save on blur or Enter. A small **ellipses (`…`) button** next to the h1 opens the polymorphic right-rail panel ("Details"; same panel slot used for Task details) showing all Initiative-level fields. Currently those fields are name and description; future fields land here too (icon, color, defaults, etc.). The description does not get its own dedicated edit affordance — it is edited inside the Details panel via the ellipses. The pencil icon from the original item 2 is removed.
12. [x] **Centered numerical percentage on progress underbars.** Refinement of items 3 and 7. The thin underbar carries the value as visible text centered inside the bar. Bar height grows from `h-1` to whatever fits readable text (~`h-4`). Text uses a high-contrast text shadow (e.g. `text-shadow: 0 0 2px rgba(0,0,0,0.7)`) so it stays legible regardless of the fill color behind it. Applies at every level — per-task underbar and Initiative-header underbar.
13. [x] **Drop "Lists & tasks" h2; depth-based title sizing.** Refinement of item 6. Remove the `Lists & tasks` section heading entirely. Inside the tree, give List titles (depth 0) a larger, bolder treatment (e.g. `text-base font-semibold`) and Task titles (depth > 0) the current `text-sm font-medium`. Visual hierarchy carries the meaning the h2 was trying to.
14. [x] **"+ New List" in h1 row; "+ New Task" on row buttons.** Refinement of item 8. The Initiative-page header gains a `+ New List` button in the h1 row, styled the same as the row-level add button. The row-level add button label changes from `+ Subtask` to `+ New Task`. Both buttons use the same icon-plus-label pill pattern with `min-h-11 min-w-11`.
15. [ ] **Botanical icon colors + actual-branch SVG.** Refinement of item 10. Tree icon renders green (`text-emerald-600` light, `text-emerald-400` dark). Branch icon renders brown (`text-amber-700` light, `text-amber-600` dark). Leaf icon stays green (consistent with tree). Replace the current Lucide `git-branch` (graph-style dot diagram) with a custom SVG that looks like an actual tree branch — a curving line with two or three offshoots.
16. [ ] **Mobile-friendly Details flyout.** Below the `lg:` breakpoint, the right-rail (Members + Details) becomes a fixed overlay that slides in from the right with a backdrop when a task or Initiative is selected. Tap-outside-the-panel or a close button dismisses it. The Members panel rides along inside the same flyout — it is part of the right-rail unit, not a separate sidebar. At `lg:` and above, behavior is unchanged from item 6.

## Non-Goals

- Drag-and-drop reordering (still deferred from M01).
- Status field redesign — explicitly removed from UI; revisit later as a fuller idea.
- Renaming List/Task to Tree/Leaf in vocabulary — the metaphor stays icon-only.
- Notifications, attachments, board/calendar views, public sharing, AI features — unchanged from M01 non-goals.
- Schema migrations beyond what individual items require (none, in current scope).

## Acceptance Criteria

- All sixteen Arc 2 items shipped and visible in the running app.
- Arc 1 complete: project-specific UX rules in `UX_GUARDRAILS.md`; M01 baseline brought up to the universal baseline (gaps Arc 2 didn't already cover are fixed).
- Initiatives can be renamed inline and have all metadata edited from the Details panel (item 11).
- Progress underbars carry a readable centered percentage at every level (item 12).
- Mobile/tablet (< `lg:`): Details panel flies out as an overlay rather than collapsing under the task list (item 16).
- Both light and dark modes pass a visual review of every primary screen.
- No regressions in M01 acceptance criteria.

## Implementation Notes

- **Theme persistence.** Persist user choice on the `users` table (or a `user_preferences` join — pick whichever fits the schema with less churn). System mode means "follow `prefers-color-scheme`" — store no override, not a literal `"system"` string, unless a column-default makes the latter cleaner.
- **Polymorphic right-rail panel.** Item 2 introduces a second selection type (Initiative) that uses the same panel slot as Task. Bind the panel's data shape to the selection type — pattern-match on the selection in the LiveView rather than branching templates inline.
- **Underbar implementation.** Prefer CSS-only driven by a `--progress` custom property; avoid layout-shifting on update.
- **Collapse-state key.** Key by `(initiative_id, task_id)` in `localStorage`; expire entries when their task is deleted.
- **Narrow-viewport breakpoint.** Pick one Tailwind breakpoint for "very narrow" (likely `sm:` boundary) and reuse it consistently for description-hide and any other narrow-mode behavior.
- **Icons before row layout.** Item 10 (icons) ships before or with item 6 (row layout); the row references the leaf/branch icon directly.

## Branch

`M02-ux-overhaul`
