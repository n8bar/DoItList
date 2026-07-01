# M06-Roles-Avatar
_Status: stub · Planned start: after M05 (Prep and Launch) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M06 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Land the role and personalization features carved out of Final Features to keep the path to launch short — a delegated admin role, a task-scoped taskmaster role, and user avatar upload. None of these gate going public; they land right after.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

- **Admin role.** A delegated tier between owner and editor: manage the roster (add / remove members, change roles below admin) without ownership — no Initiative delete, no ownership transfer. Pairs with the invite system; when it lands, ownership transfer demotes the old owner to **admin** instead of today's editor.
- **Taskmaster — a task-scoped full-control role.** Like viewer+ ([`m02.05`](../m02-ux-buildout/m02.05-wide-width-layout.md) item 12.6) but stronger: full editor-level control over the task they're the direct assignee of *and its whole subtree* — without rights to the rest of the Initiative. The natural step up from viewer+.
- **Avatar upload.** User-supplied avatar images replacing/augmenting the generated ones from [`m02.04`](../m02-ux-buildout/m02.04-account-details.md) — brings file storage, serving, size limits, image processing.

## Preconditions

- M02 (UX Buildout) lands — membership, roster, and account surfaces this work extends are stable.
- M04 (Final Features) lands — the invite system Admin role pairs with is there.

## Open Questions

- Whether avatar storage uses local disk vs object storage (interacts with M05 hosting).

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M06-roles-avatar` (created at scoping time).
