# Skill Authoring

_Draft — pending operator approval._

## Layering — where content belongs

Each layer owns one question. Placement is by how often content changes, not by who knows it — nothing is exclusive to a layer; everything is allocated to one.

- **API — what is allowed to happen.** The enforced contract: authz, atomicity, idempotency, caps. Makes wrong things impossible, so the skill never teaches safety.
- **MCP — what calls exist, how to make them.** Discovery plus per-verb mechanics: schemas, params, ceilings. No cross-tool judgment.
- **Skill — the tested defaults for everything the prompt leaves unsaid.** Cross-project constants: judgment pre-answered once, versioned, drive-tested — the only layer under regression; the same sentence in a prompt is unaudited and dies with the ask. Per-project constants live in the domain object — the Initiative's AI-knobs — not in skill copies users never open; the skill's Knobs section only suggests a starting point or default set. The skill's job is to make the prompt's minimum size tiny.
- **Prompts — what varies per ask.** Intent (verb, source, destination, scope) plus deliberate overrides — at runtime the prompt beats the skill. Coaching is legitimate as override; harmful when it substitutes for a missing default — and drive prompts are the skill's test inputs, so coaching there contaminates the test.

**Placement rule:** enforceable → API; per-verb → MCP schema; cross-project default → skill; per-project constant → the Initiative (AI-knobs); varies per ask → prompt.

**Migration rule** (placement's dynamic counterpart): content moves by observed frequency. Said twice across prompts → promote to the skill (every delta so far was this). A rule that keeps needing per-project override → demote to a knob. A knob nobody turns → fold into the rule. Constants sink as they stabilize — prompt → skill → Initiative → product column; `index_style` completed the whole journey.

**Bounded judgment** (the middle the layer split hides): the hooks that work don't decide for the agent — they fix the moment, the range, and the output form, and the agent supplies the value. The checkpoint fixes the moment, the readback slot the range, the grade-as-written frame the form. Exhortation leaves all three open and drifts; enforcement closes all three and can't judge.

## Drive protocol — closing instruments

End every refinement drive with two prompts, run separately:

- **Behavior audit:** "Consider the work you just ran. Re-read each rule of the skill, then summarize what you'd do differently — without judgment of the rules themselves." The frame is load-bearing: object is the artifact, standard is the skill as written, rule critique is out of scope. Anchor claims to facts (`ingest_report`, the live tree), never the agent's recollection — memory-based self-audit produces lobbying, not auditing. Even anchored, its verdicts are hypotheses: verify each against the tree before acting on one — drive 4's self-eval confessed a miss it hadn't committed, and its remediation plan would have "fixed" it.
- **Hypocrisy diff:** separately invite the rule-by-rule critique, then diff its keeps/changes against its actual violations. Endorsed-and-broken → the rule needs a mechanical hook (checkpoint line, tool-description pointer). Contested-and-broken → the rule needs carried rationale and the Standing contract. Its factual finds are harvest; its rule lobbying is data, not direction.
