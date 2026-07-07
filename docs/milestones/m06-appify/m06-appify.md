# M06-Appify
_Status: stub · Planned start: after M05 (Prep and Launch) · Target: TBD_

> Canonical product behavior, vocabulary, and the roll-up formula live in [`ProductSpec.md`](../../ProductSpec.md). Universal UX/a11y baseline lives in [`UX_GUARDRAILS.md`](../../UX_GUARDRAILS.md). This milestone doc owns M06 scope and acceptance criteria once it's scoped; per-arc detail will live in arc files linked below.

## Goal

"Appify" the existing web frontend — ship Do It List as installable **Android and iOS apps** by wrapping the current Phoenix/LiveView UI in a store-shippable mobile shell, rather than building a separate native client. Post-launch: a wrapped app needs the public, hosted instance from M05 to point at.

## Status

Stub — to be expanded. Not yet scoped into arcs.

## Planned scope

- **Delivery approach (decide first).** Installable PWA (no store, web-push) vs. a store-shipped native shell wrapping the web app (e.g. a WebView/Capacitor-style wrapper) — the pick trades store presence + native push against reach and overhead.
- **App-store presence.** Google Play + Apple App Store listings, icons, splash, and store-review compliance (Apple's wrapper-app rules especially).
- **Push notifications.** Wire the existing notification model to device push (APNs / FCM) or web-push, depending on the delivery approach.
- **Native shell affordances.** Home-screen install, deep links into an Initiative / task (reuse the existing `deep-link-task` primitive), back-button / navigation handling, and secure API-token / session storage on device.
- **Mobile UI pass.** Confirm the M02 responsive layout holds on phone form factors; fill mobile-specific touch and safe-area gaps.
- **Offline posture.** Decide how much functions offline (read-only cache vs. none) given the real-time collaborative model.

## Preconditions

- M05 (Prep and Launch) lands — a public, hosted, TLS instance for the apps to point at; a wrapped app has no local server to talk to.
- M02 (UX Buildout) responsive/touch baseline holds on phone-sized viewports.

## Open Questions

- PWA vs. native-shell wrapper — reach (no store friction) against app-store presence and native push.
- Push transport: native (APNs / FCM) vs. web-push, and how each maps onto the notification model.
- How much offline support the real-time collaborative model actually warrants.
- Developer-program enrollment + review overhead (Apple in particular) and what it implies for release cadence.

## Non-Goals

_(TBD once scoped.)_

## Acceptance Criteria

_(TBD once scoped.)_

## Branch

`M06-appify` (created at scoping time).
