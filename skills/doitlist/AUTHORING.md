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
