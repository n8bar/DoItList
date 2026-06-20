# M05-Final-Features
_Status: stub · Planned start: after M04 (Templates & Reuse) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M05 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Land the **last product features** before going public — the account, security, membership, and monetization pieces that the private app has done without. After this milestone the product is **feature-complete**; M06 is preparation and launch, not new functionality.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

- **Email infrastructure & invites.** A mailer plus everything gated on it: email verification on change/registration, email-based password reset, and the **invite system** — "add a member" becomes an *invite* (a pending membership that can already hold task assignments before acceptance; pending assignees show dimmed with a dashed border until they join). An invite reaches an existing account or an email with no matching account (auto-joining them if they later register), binds to whichever account accepts it, and shows as pending in the roster (removable). Invitees are notified in-app + by email. The foundation most of the rest leans on.
- **Recovery codes.** One-time codes (generated on the account page, shown once, hashed at rest) with a "use a recovery code" login path. The public-opening gate while admin resets won't scale.
- **TOTP two-factor.** Security, not recovery — pairs with recovery codes (or the live mailer) so 2FA lockouts have an exit.
- **Avatar upload.** User-supplied avatar images replacing/augmenting the generated ones from [`m02.04`](../m02-ux-buildout/m02.04-account-details.md) — brings file storage, serving, size limits, image processing.
- **Admin role.** A delegated tier between owner and editor: manage the roster (add / remove members, change roles below admin) without ownership — no Initiative delete, no ownership transfer. Pairs with the invite system; when it lands, ownership transfer demotes the old owner to **admin** instead of today's editor.
- **Taskmaster — a task-scoped full-control role.** Like viewer+ ([`m02.05`](../m02-ux-buildout/m02.05-wide-width-layout.md) item 12.6) but stronger: full editor-level control over the task they're the direct assignee of *and its whole subtree* — without rights to the rest of the Initiative. The natural step up from viewer+.
- **Donation screen.** A "support this project" page — suggested amounts + a payment-processor integration (Stripe or similar), linked from the nav / account menu. Brings a payment-processor dependency. (Only meaningful once there's a public audience, so it rides with the public-open work.)

## Preconditions

- M02 (UX Buildout) lands — membership, roster, and account surfaces the invite/role/avatar work extends are stable.
- Email infrastructure is foundational here: invites, verification, and email password reset all gate on the mailer.

## Open Questions

- Mailer provider / transport (transactional email service vs self-hosted SMTP).
- Payment processor for the donation screen, and what compliance it pulls in.
- Whether avatar storage uses local disk vs object storage (interacts with M06 hosting).

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M05-final-features` (created at scoping time).
