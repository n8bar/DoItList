# M01-BaseApp
_Status: complete · Completed: 2026-05-05_

> Canonical product principles, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). This milestone doc owns scope, acceptance criteria, and the detailed edge cases for the behaviors it introduces.

## Goal

Build the first usable version of Do It List.

M01-BaseApp should prove the core product idea:

> A shared task tree where progress rolls up automatically from child tasks.

This milestone is not the full product. It is the first working slice.

## Target Stack

- Phoenix LiveView
- PostgreSQL
- Docker Compose

## Required Features

### Accounts

- User registration
- User login
- User logout

### Projects

- Create project
- View project list
- Open project detail page

### Project Members

- Associate users with projects
- Support simple roles:
  - owner
  - editor
  - viewer

Advanced permissions are not required yet.

### Tasks

Tasks must support:

- title
- optional description
- project
- parent task
- status
- priority
- manual progress
- computed progress
- weight (so the user can make it a custom percentage of it's parent)
- optional assignee
- comments
- sort order
- created by
- updated by

### Nested Task Tree

Users must be able to:

- create root tasks (aka separate Lists)
- create child tasks
- view tasks nested under parents
- update leaf task progress
- update task weight
- update status
- assign a task to themselves or another user

Drag/drop ordering is not required for this milestone.

## Progress Rules

Progress roll-up is a key feature.

Rules:

- Tasks without children use manual progress.
- Tasks with children use calculated progress.
- Root task progress is read-only.
- Default child weight is 1.
- Weighted progress formula:

```text
sum(child_progress * child_weight) / sum(child_weight)
```

- Changing a child task's progress updates parent progress.
- Changing a child task's weight updates parent progress.
- Progress should roll up recursively through ancestors.
- Marking a task done sets progress to 100.
- Reopening a done task allows progress below 100.

## Collaboration Behavior

For this milestone:

- Multiple users may open the same Tasklist.
- Changes save immediately and update on other active users' screens promptly.
- Last writer wins.
- Track who last updated a task and when. (should be accessible info in the UI)
- Do not implement check-in/check-out.
- Do not build conflict resolution yet.

## Activity Log

Create a basic task activity/event log.

It should record meaningful task changes such as:

- task created
- title changed
- status changed
- progress changed
- weight changed
- assignee changed

The UI only needs a simple activity display.

## Non-Goals

Do not build these in this milestone:

- attachments
- Gantt charts
- Kanban board
- calendar view
- notifications
- billing
- public sharing
- import/export
- drag/drop sorting
- advanced permissions
- AI features

## Acceptance Criteria

This milestone is complete when:

- The app starts with `docker compose up --build`.
- A user can register and log in.
- A user can create a project.
- A user can create nested tasks inside a project.
- A user can update progress on leaf tasks.
- Parent progress calculates from child tasks.
- Weighted progress works correctly.
- Roll-up progress updates recursively.
- A task can be assigned to a project member.
- A basic activity log records task changes.
- The README explains how to run the app through Docker.
- Progress calculation has automated tests.

## Implementation Notes

Keep the implementation simple.

Do not optimize for every future feature yet.

Do not build a generic project management suite.

Protect the core idea: nested task trees with real progress.
