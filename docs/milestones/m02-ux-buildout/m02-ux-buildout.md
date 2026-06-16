# M02-UX-Buildout
_Status: in progress · Target: 2026-05-29_

> Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). This milestone doc owns M02 scope and acceptance criteria; per-arc detail lives in the arc files linked below.

## Goal

Bring the M01 baseline app up to the UX guardrails and apply a set of targeted design refinements so the product feels presentable.

This is the milestone that earns the first public release.

## Preconditions

- The vocabulary rename of Project → Initiative is complete. M02 items reference the final vocabulary.

## Arcs

| Arc | Doc | Items | Status |
|---|---|---|---|
| 1 — Bring M01 to spec | [`m02.01-bring-to-spec.md`](m02.01-bring-to-spec.md) | 2 | complete |
| 2 — Design Refinements | [`m02.02-design-refinements.md`](m02.02-design-refinements.md) | 27 | complete |
| 3 — Task Tree: Reorganization & Layout | [`m02.03-task-tree.md`](m02.03-task-tree.md) | 11 worklists | complete |
| 4 — Account Details | [`m02.04-account-details.md`](m02.04-account-details.md) | 3 worklists | complete |
| 5 — Wide-Width Layout | [`m02.05-wide-width-layout.md`](m02.05-wide-width-layout.md) | 12 + O&C | code complete; My Collaborators refinements drafted (12.9–12.11) |
| 6 — Undo & Trash | [`m02.06-undo-redo.md`](m02.06-undo-redo.md) | 13 | in progress (item 12 blocked) |
| 7 — Personal Workspace | [`m02.07-personal-workspace.md`](m02.07-personal-workspace.md) | 8 | draft |

## Non-Goals

- Status field redesign — explicitly removed from UI; revisit later as a fuller idea.
- Renaming List/Task to Tree/Leaf in vocabulary — the metaphor stays icon-only.
- Attachments, board/calendar views, public sharing, AI features — unchanged from M01 non-goals. (Notifications moved *into* scope — Arc 7 item 6.)
- Schema migrations beyond what individual items require (Arcs 4/5/7 add the ones their items need).

## Acceptance Criteria

- All Arc 1 and Arc 2 items shipped and visible in the running app.
- Arc 1 complete: project-specific UX rules in `UX_GUARDRAILS.md`; M01 baseline brought up to the universal baseline (gaps Arc 2 didn't already cover are fixed).
- Initiatives can be renamed inline and have all metadata edited from the Details panel (Arc 2 item 11).
- Progress underbars carry a readable centered percentage at every level (Arc 2 item 12).
- Mobile/tablet (< `lg:`): Details panel flies out as an overlay rather than collapsing under the task list (Arc 2 item 16).
- Both light and dark modes pass a visual review of every primary screen.
- No regressions in M01 acceptance criteria.

## Branch

`M02-ux-buildout`
