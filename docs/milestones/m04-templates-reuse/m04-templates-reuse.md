# M04-Templates-Reuse
_Status: stub · Planned start: after M03 (API & MCP) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M04 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Make task trees **reusable**. Today every Initiative starts from a blank canvas; this milestone lets a tree be copied into a fresh owned Initiative — from a template, from a duplicate, or from a trashed Initiative you only had access to.

These items share one core mechanism — **copy a tree's skeleton into a new owned Initiative, instantiated fresh** (no assignments, progress, members, or activity carried over) — which is why they belong together.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

- **Initiative templates.** Pre-built task trees that instantiate into a fresh Initiative. Three layers at very different sizes: (1) curated / built-in starters shipped with the app; (2) save-as-template from one of your own Initiatives or a subtree; (3) sharing / a template library (the big one — discovery, attribution, permissions, moderation). A template captures the tree skeleton (titles, nesting, optionally priorities / sort modes / progress-calc) and instantiates fresh.
- **Duplicate a non-owned initiative.** Copy an Initiative you don't own into a brand-new one you do — new tasks, fresh timestamps, not a clone of history. Owners can disable duplication per-Initiative, but it's a soft barrier only (manual recreation is always possible; make owners aware).
- **Trash ↔ duplicate interplay.** An owner-trashed Initiative ([`m02.06`](../m02-ux-buildout/m02.06-undo-redo.md) Trash) shows to its members as an unowned item in their Trash; unless the owner disabled duplication, they can duplicate it before it's permanently purged.

## Preconditions

- M02 (UX Buildout) lands — stable task-tree, membership, and Trash models to copy from.

## Open Questions

- Does the **template library / sharing** layer (templates layer 3) split into its own milestone? It's much larger than the curated + save-as layers and may warrant separation.
- Shared copy-a-tree engine: one internal module powering templates, duplicate, and trash-duplicate, or separate paths?
- What exactly a template skeleton captures beyond titles + nesting (priorities, sort modes, progress-calc mode, index style).

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M04-templates-reuse` (created at scoping time).
