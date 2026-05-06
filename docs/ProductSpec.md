# Product Spec
_Last updated: 2026-05-05_

The canonical specification of Do It List — what the product is, the vocabulary used to describe it, the principles it must hold to, and the headline behaviors that define it.

This is the master spec. Milestone docs and subsystem specs narrow or extend it but do not contradict it. [`PLAN.md`](PLAN.md) tracks how we get there; this doc tracks what "there" means.

## Core Idea
**Task trees with real progress.** Break work into nested tasks; update progress on leaves; parent progress rolls up automatically. Weighting is optional but available for users who need accuracy.

This is not a generic todo app. Nested work is first-class.

## Product Inspiration
Heavily inspired by AbstractSpoon's ToDo List, with three deliberate departures:
1. Web-based, not a Windows desktop app.
2. Real-time collaborative — multiple users edit simultaneously with near-instant updates.
3. Simpler — features earn their place only if they keep the UI clean.

## Vocabulary
- **Project** — the top-level container; has members and a tree of tasks.
- **Task** — any node in the tree.
- **List** — informal name for a *root* task (a task whose `parent_id` is null). A project usually has multiple Lists, each with its own tree.
- **Progress** — a task's current completion (0–100). Manual on leaves, computed on branches.
- **Roll-up progress** — a branch task's computed progress: the weighted average of its children's rolled-up progress.
- **Weight** — how much a child contributes to its parent's roll-up. Default `1`.
- **Project member** — a `(user, project, role)` triple. Roles: `owner`, `editor`, `viewer`.

## Durable Principles
- **Nested work is first-class.** The tree is the point.
- **Progress is useful by default.** A user who never touches weights still gets meaningful roll-up.
- **Weighting is optional, never required.** Users opt in to non-equal contributions.
- **No file check-in/check-out collaboration.** Real-time, last-writer-wins by default.
- **Grow milestone by milestone.** Resist becoming bloated PM software.

## Roll-up Progress (principle + formula)
Leaf tasks use manual progress. Branch tasks use computed progress:

```
sum(child_progress * child_weight) / sum(child_weight)
```

Roll-up is recursive through ancestors. Edge cases (non-positive weights, status transitions, root-task behavior) are owned by the milestone doc that introduced them — currently [`milestones/m01-baseapp/m01-baseapp.md`](milestones/m01-baseapp/m01-baseapp.md) → "Progress Rules".

## Collaboration Model
- Multiple users may open the same project simultaneously.
- Changes save immediately and propagate to other active users promptly.
- Last writer wins. No check-in/check-out, no file locking, no conflict resolution UI.
- Each task records who last updated it and when, accessible in the UI.
