# FINDINGS
_Last updated: 2026-05-08_

Observation log. Anything noticed during dogfooding, manual QA, automated test triage, user reports, security review, browser quirks, or any other testing surface gets a numbered entry here.

## Conventions
1. Each entry has an ID (`F#01`, `F#02`, …), a short title, a longer description, and a status.
2. Statuses: `open` (just observed), `triaged` (assessed and routed), `promoted` (an unchecked action item owns the fix; see rule 6), `fixed` (with a link to the resolving change), `deferred` (intentionally not scheduled, with the reason).
3. Append new entries at the bottom; never renumber existing ones.
4. Entries are not deleted when fixed — they get marked `fixed` with a link. Findings are a record, not a queue.
5. Action lists (milestones, worklists) reference findings by ID (`F#14`) and never duplicate the observation content. The fix details live in the action list; the original observation lives here.
6. Promotion is explicit. A finding is `promoted` when an unchecked action item in some milestone/worklist owns the fix at the moment the status flips. Set the status and link the owning action list.
7. **Pre-scoped refinements are not findings.** If an upcoming milestone or arc already explicitly covers a gap, do not log it here — it's already on the list. This file is for surprises, not for re-stating known work.
8. **Two paths to a fix.** A finding may be either *promoted* (per rules 5–6: a milestone/worklist owns the fix description) or *fixed inline* (the finding itself documents the planned fix). Pick **promote** when the fix needs scoping, design decisions, or coordinated work; pick **inline** when it's small and contained. For the inline path, write a `**[ ] fix:**` paragraph in the finding body before implementation; flip to `**[x] fix:**` (with a link to the commit) when it lands and update status to `fixed`. The doc-before-implement rule applies to both paths. If an inline-fix grows beyond what's contained, promote it — move the fix description into a milestone/worklist and update status to `promoted`.

## Findings
_None yet._
