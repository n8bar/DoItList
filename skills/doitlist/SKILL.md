---
name: doitlist
description: Use when representing a code repository's roadmap, milestones, or ongoing todos as a Do It List Initiative through the doitlist MCP tools — before creating or restructuring Initiatives, tasks, comments, or their numbering.
---

# Do It List

## Overview

**Do It List** is task trees with real, rolled-up progress: nest the work, update the leaves, and parents roll up automatically. Importance is expressed by **decomposition** — how finely you break work down.

Driving it over MCP means editing a real person's live workspace. Two habits follow:

- **Mirror the repo's actual structure** into the tree. The tree is the source of truth, not a scratch copy of your notes.
- **Record changes as you make them**, so the human can follow what you did without re-reading the whole tree.

This skill is the *conventions*; each MCP tool documents its own params.

## When to Use

- Mapping a repository's roadmap / milestones / todos into a new Initiative.
- Restructuring, reordering, or advancing progress on an Initiative you already built.

## Vocabulary

The Initiative is the **Project**. Below it, the levels are:

**Project (Initiative) › Milestone › Arc › Worklist › item › subitem**

Every level is a Task in the same tree. Use **Worklist** as the name for the level under Arc even when a repo doesn't label it explicitly.

- Name the level under Milestone **Arc** by default. **Phase** is a per-repo override — use it only when that repo already calls them phases.

## Setting Up the Initiative

- **Numbering on.** Create every Initiative with `index_style: "numerical"`. The product default is `none`; you turn it on because references and cross-links depend on labels existing. Turn it off only if the operator asks.
- **Placeholder milestones.** When the repo's milestones don't start at 1 — you're mapping M19 onward — create placeholder Milestone tasks (`M1`…`M18`) so the numbering lines up: real work lands at `19.3.1`, not `1.3.1`.
- Build a whole subtree in one atomic `apply_operations` batch using `lid` forward-references, rather than a task at a time.

## Titling Tasks

- **Don't repeat the auto-number.** A task the numbering already labels `19.3.1` is titled with its content — `CyberCreek ingest` — never `1. CyberCreek ingest`. The index carries the number; the title carries the content.
- **Label the top two levels.** The exception: a Milestone keeps its label (`M19 — Open Beta`) and an Arc keeps its label (`Arc 1 — Ingest`). Everything below is content-only.

## Where Information Lives

- **Journaling → comments.** Moves, status changes, and decisions go in **task comments** (`add_comment`) — a running journal on the task. **Never** the description.
- **Description → how-to / overflow.** A task's description is for how-to, a concise overflow the title can't hold, or action subitems. **Never** a change journal.

## Talking to the Operator

- Reference a task by its **number** (`19.3.1`) — always. Add the title on first mention, or when the number alone is ambiguous.

## Quick Reference

All tools and resources below are on the `doitlist` MCP server.

| Intent | Tool / resource |
|---|---|
| Create an Initiative (numbering on) | `create_initiative` `{index_style: "numerical"}` |
| Build/reshape a whole subtree atomically | `apply_operations` (`lid` forward-refs; batch cap — see tool help) |
| Add one task | `create_task` `{initiative_id \| parent_id, title, position}` |
| Reparent / reorder | `move_task` `{task_id, parent_id?, position?, reorder?}` |
| Set progress / mark done | `update_task` `{manual_progress}` / `complete_task` |
| Journal a move, status change, or decision | `add_comment` `{task_id, body}` |
| Read the current tree + live labels | `initiative_tree` resource |
| Read a task's comment journal | `task_comments` resource |

## Common Mistakes

- Prefixing a title with its number "for clarity" (`1. Foo`) when the index already shows `19.3.1` → the title is just `Foo`.
- Journaling into the description because it's the field in front of you → moves, status changes, and decisions belong in a comment.

## Knobs (per-repo overrides)

A stranger adopting this skill should treat these as tunable, not fixed:

- **Numbering** — on here; `none` is valid for an Initiative that doesn't need referenceability.
- **Arc vs Phase** — Arc default; Phase per-repo.
- **Worklist labeling** — opt-in per repo (otherwise the level is unlabeled but still *called* a Worklist).
- **Placeholder milestones vs. an offset** — placeholders by default; an Initiative-level numbering offset that removes the need is on the product backlog.
