# Skill Authoring

_Draft — pending operator approval._

## Layering — where content belongs

Each layer owns one question; content in the wrong layer is how skills rot.

- **API — what is allowed to happen.** The enforced contract: authz, atomicity, idempotency, caps. Makes wrong things impossible, so the skill never teaches safety.
- **MCP — what calls exist, how to make them.** Discovery plus per-verb mechanics: schemas, params, ceilings. No cross-tool judgment.
- **Skill — how to behave across the verbs.** Cross-tool, cross-session judgment no schema can say and no server can enforce. The only layer tuned empirically — judgment is what fails empirically.
- **Prompts — what only the human knows.** The residue: verb, source, destination, scope intent. Uncoached on purpose — drive prompts are the skill's test inputs, and coaching contaminates the test.

**Placement rule:** enforceable → API; per-verb → MCP schema; cross-verb judgment → skill; only-the-user-knows → prompt.
