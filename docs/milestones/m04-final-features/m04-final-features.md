# M04-Final-Features
_Status: stub · Planned start: after M03 (API & MCP) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M04 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

Land the **last product features** before going public — the account, security, and monetization pieces that the private app has done without. After this milestone the product is **feature-complete** for launch; M05 is preparation and launch, not new functionality. (Admin role, taskmaster, and avatar upload are real features too, but they don't gate launch — they're M07, just after.)

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

- **Email infrastructure & invites.** A mailer plus everything gated on it: email verification on change/registration, email-based password reset, and the **invite system** — "add a member" becomes an *invite* (a pending membership that can already hold task assignments before acceptance; pending assignees show dimmed with a dashed border until they join). An invite reaches an existing account or an email with no matching account (auto-joining them if they later register), binds to whichever account accepts it, and shows as pending in the roster (removable). Invitees are notified in-app + by email. The foundation most of the rest leans on.
- **Recovery codes.** One-time codes (generated on the account page, shown once, hashed at rest) with a "use a recovery code" login path. The public-opening gate while admin resets won't scale.
- **TOTP two-factor.** Security, not recovery — pairs with recovery codes (or the live mailer) so 2FA lockouts have an exit.
- **GUIDs for Initiative ids.** Replace the sequential integer Initiative id with a GUID in URLs and the API/MCP surface — sequential ids leak count/ordering and invite guessing once those surfaces are public; ids stay plumbing either way (agents resolve Initiatives by name). Must land before M05 opens the API/MCP.
- **Donation screen.** A "support this project" page — suggested amounts + a payment-processor integration (Stripe or similar), linked from the nav / account menu. Brings a payment-processor dependency. (Only meaningful once there's a public audience, so it rides with the public-open work.)

## Optional

- **Task indexes — deferred extras.** Follow-ups to the fixed index styles from [`m02.07`](../m02-ux-buildout/m02.07-layout+task-tree-revisited.md) (item 1.7): **Custom Outline** (pick the glyph set per level), a **depth-flat variant** (`1.`, `2.` per level, no ancestor prefix), and a **continue-across-collapse** toggle. If deferred, it doesn't make the first release — and that's fine.

## Preconditions

- M02 (UX Buildout) lands — membership, roster, and account surfaces the invite/role work extends are stable.
- Email infrastructure is foundational here: invites, verification, and email password reset all gate on the mailer.

## Open Questions

- Mailer provider / transport (transactional email service vs self-hosted SMTP).
- Payment processor for the donation screen, and what compliance it pulls in.

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M04-final-features` (created at scoping time).
