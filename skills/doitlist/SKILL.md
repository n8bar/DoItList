---
name: doitlist
description: Use when representing a project's roadmap, milestones, or to-do list as a Do It List Initiative through the doitlist MCP tools — before creating or restructuring Initiatives, tasks, comments, or their numbering.
---

# Do It List

## Overview

**Do It List** is task trees with real, rolled-up progress: nest the work, update the leaves, and parents roll up automatically. Importance is expressed by **decomposition** — how finely you break work down.

Driving it over MCP means editing a real person's live workspace. Two habits follow:

- **Mirror the project's actual structure** into the tree. The tree is the source of truth, not a scratch copy of your notes.
- **Record changes as you make them**, so the human can follow what you did without re-reading the whole tree.

This skill is the *conventions*; each MCP tool documents its own params.

## When to Use

- Mapping a project's roadmap, milestones, or to-do list into a new Initiative — the source might be a code repo, a planning doc, or the conversation itself.
- Restructuring, reordering, or advancing progress on an Initiative you already built.
- Expanding, adding details, commenting on, or managing an existing Initiative.

## DoItList's structure (what you map onto)

An **Initiative** (the Project) holds **Tasks** nested into a tree — arbitrarily deep, and it can hold several top-level trees (**Lists**). A task with children is a **branch**; its Progress rolls up from its descendant **leaves**, whose progress is set directly. That's the whole structure — all DoItList knows.

## Mapping a project onto it

A project's rank names are its own — DoItList has no opinion. Learn them from the source's terms (a repo already saying "Milestone" / "Sprint" / "Phase") or by asking, and apply them consistently top to bottom. Projects tend to name their first up to 3–4 ranks (`Milestone › Arc › Worklist`) and go generic ("item") below — DoItList's branch-vs-leaf split exactly. Names live in **task titles**, not any field: the top ranks carry their label (`M19 — …`, `Arc 1 — …`, per Titling); deeper items are content-only.

## Setting Up the Initiative

- **Numbering on.** Give every Initiative a label style (`index_style`) — references and cross-links need labels to exist (product default is `none`, off). Pick what fits the project: `numerical` (`1.1.2`, the usual choice), `outline` (`I.A.1.a.i`), `roman` (`I.II.III`), or `alphabetical` (`A.B.C`). Leave it `none` only if the operator asks.
- **Placeholder milestones.** When the project's milestones don't start at 1 — you're mapping M19 onward — create placeholder Milestone tasks (`M1`…`M18`) so the numbering lines up: real work lands at `19.3.1`, not `1.3.1`. If numbering isn't obvious but likely exists -example: a task "C3 Liquids" exists followed by "C4 Explosives", ask for user clarification before proceeding.
- Prefer build a whole subtree in one atomic `apply_operations` batch using `lid` forward-references, rather than a task at a time.

## Accessing an Existing Initiative for the first time
- **Offer to turn numbering on** (app default is `none`, off) — recommend a style that fits (`numerical` usual; also `outline` / `roman` / `alphabetical`); references and cross-links depend on labels existing.

## Titling Tasks

- **Don't repeat the auto-number.** A task the numbering already labels `19.3.1` is titled with its content — `CyberCreek ingest` — not `19.3.1. CyberCreek ingest` and not `1. CyberCreek ingest`. The index carries the number; the title carries the content.
- **Label the top named ranks (~2-4 deep).** Exception to the rule above: the top ranks that act as named anchors keep their label in the title (e.g. `M19 — Open Beta`, `Arc 1 — Ingest`) — judgment call how far that goes; everything below is content-only.

## Where Information Lives

- **Journaling → comments.** Moves, status changes, and decisions go in **task comments** (`add_comment`) — a running journal on the task. **Never** the description.
- **Description → how-to / overflow.** A task's description is for how-to, a concise overflow the title can't hold, or action subitems. **Never** a change journal.

## Talking to the Operator

- Reference a task by its **number** (`19.3.1`) — always. Add the title on first mention, or when the number alone is ambiguous.

## Quick Reference

The common moves — all on the `doitlist` MCP server. Full params live in each tool's own schema (`tools/list`); only the convention-relevant ones are noted here.

| Intent | Tool |
|---|---|
| Create an Initiative | `create_initiative` — set `index_style` (`numerical` / `outline` / `roman` / `alphabetical`) to turn numbering on |
| Build or reshape a whole subtree at once | `apply_operations` — one atomic batch; `lid` forward-refs beat a loop of single calls |
| Add one task | `create_task` |
| Reparent or reorder | `move_task` — set `reorder` for an explicit sibling reorder |
| Set a leaf's progress | `update_task` — `manual_progress` |
| Mark a task (and its subtree) done | `complete_task` |
| Journal a move, status change, or decision | `add_comment` — the running journal, never the description |
| Read the current tree + live labels | `get_initiative_tree` |
| Read a task's comment journal | `get_task_comments` |

## Common Mistakes

- Prefixing a title with its number "for clarity" (`1. Foo`) when the index already shows `19.3.1` → the title is just `Foo`.
- Journaling into the description because it's the field in front of you → moves, status changes, and decisions belong in a comment.

## Knobs (per-project overrides)

Anyone adopting this skill should treat these as tunable, not fixed:

- **Numbering & style** — on here; the style (`numerical` / `outline` / `roman` / `alphabetical`) fits the project, and `none` (off) is valid when referenceability isn't needed.
- **Placeholder milestones vs. an offset** — placeholders by default; 
