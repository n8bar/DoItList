# MCP Rule Standard

Agent-facing rules in `mcp_server/**/*.ex` use the least text that reliably produces the intended behavior.

## Rule form

Each rule has:

1. one clear trigger;
2. one required behavior;
3. explicit constraints or ordered priorities;
4. only necessary exceptions, adjacent to the rule.

Write decisive imperatives. Use **always** and **never** only for true invariants. For a judgment call, always name what determines the choice; never leave "best," "appropriate," or "as needed" undefined.

State the action before any necessary rationale. Keep rationale only when it prevents a likely misreading. Keep an example only when it distinguishes behavior the rule cannot state as concisely.

## Coherence and concision

- Use one term for one concept.
- Remove duplicated rules and rationale without removing obligations, priorities, exceptions, or recovery paths.
- Never contradict another agent-facing instruction; resolve overlaps into one coherent rule.
- Remove every word that does not change the agent's decision or action.

## Review test

Before accepting a rule, answer:

1. What behavior must it guarantee?
2. Is it an invariant or a judgment rule?
3. What triggers it?
4. What exact action or decision criteria does it require?
5. Can it conflict with another instruction?
6. Can any word be removed without weakening or changing the behavior?
