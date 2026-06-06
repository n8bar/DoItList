# UX_GUARDRAILS
_Last updated: 2026-06-06_

Universal UX/a11y baseline. Apply on every UI change. This doc is universal principles only — project-specific standards live in [`ProductSpec.md`](ProductSpec.md).

Keep this doc tight. If the universal baseline grows past ~25 rules, it stops being read.

## Universal Baseline

### 1. Layout & motion
1.1 No layout shift after initial render. Reserve space for async/late content; never let arriving elements push earlier ones.
1.2 Respect `prefers-reduced-motion`. Decorative animation off by default for users who opt out.
1.3 Mobile-first sizing. Default to fluid layouts; explicit breakpoints, not fixed pixel widths.

### 2. Input & error handling
2.1 Preserve user input on validation errors. Forms re-render with submitted values; never make a user re-type.
2.2 Surface errors near their source — next to the field that caused them, not at the top of the form unless the error is page-level.
2.3 Error messages explain the cause and a path forward. Avoid "An error occurred"; say what happened and what to try.
2.4 Empty states tell the user what to do next. Never just an empty screen.

### 3. Focus & keyboard
3.1 Focus moves into a dialog when it opens and returns to the trigger when it closes. Never trap focus indefinitely.
3.2 Visible focus indicators always. Don't suppress outlines without providing a clear replacement.
3.3 Keyboard reachability: every interactive element must be operable by keyboard alone; tab order matches visual order.

### 4. Naming & contrast
4.1 Every interactive element has a discernible accessible name (visible label, `aria-label`, or `aria-labelledby`).
4.2 Text meets WCAG AA contrast (4.5:1 normal, 3:1 large). Verify before shipping.

### 5. Touch & sizing
5.1 Touch targets ≥ 44×44px on mobile/touch surfaces.
5.2 Layouts tolerate ~30% string growth without breaking — for translations and longer-than-expected content.

### 6. Loading & action feedback
6.1 Operations longer than ~100ms show progress immediately.
6.2 Optimistic UI for fast operations: reflect the action instantly when likely to succeed; reconcile on error.
6.3 Confirmations only for destructive or irreversible actions. Don't gate ordinary actions behind "are you sure?"
6.4 Prefer undo over confirm where feasible — let the user act, with a short window to reverse.

### 7. Navigation & state
7.1 Same path = same content. Back button works as expected; refreshing a page returns the user where they were.
7.2 Don't override system color-scheme preference unless the user explicitly opted in.
