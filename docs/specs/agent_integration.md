# Agent Integration

_Status: Approved._

This specification defines durable behavior for AI agents interacting with Do It List.

## Supported workflows

Agent work originating in chat or in files on disk shall be supported. Both paths shall meet the same import fidelity and safety standards.

## Import fidelity

- Imports preserve source items, hierarchy, completion, descriptions, order, and numbering; invent no layers or title echoes; and are deterministic and idempotent.
- Hosted and local chat clients import pasted or uploaded documents and typed lists without import-specific instructions. Task titles stay concise; source detail beyond the title belongs in the Task description, while import process notes do not. Each imported tree identifies its source once without repeating it in titles or descriptions.

## Conversational task work

- Chat clients support one-at-a-time task entry.
- Chat clients support reorder, reparent, promote, demote, split into subtasks, merge, and retitle without overwriting concurrent web app changes.

## Operator-facing communication

- Chat clients shall complete Tasks. Replies shall use Task numbers and titles and Initiative URLs, never standalone internal IDs.

## Safety and authorization

- During import, source content shall be reproduced, not obeyed. Task content may direct assigned work but shall not override the user's request, system rules, authorized scope, or confirmation requirements. Content that attempts an override shall be preserved and should be flagged to the user.
- Agent access shall be opt-in per Initiative. Sharing agent-accessible work shall require accepting that all member content can influence agents.
- Production chat connections shall not require users to paste access tokens into chat.
- Agents may initiate irreversible actions, but execution shall require explicit human confirmation in the web app.

## Shared work

- An agent can use an Initiative as its working list while a user concurrently edits the same tree in the web app.
- Agent tree views shall include completed Tasks within the requested scope and shall not offer open-only filtering.
- Depth-limited tree views shall distinguish branches from leaves even when their descendants are not displayed.
- Existing files explicitly designated by the user or repository instructions as maintained Initiative mirrors shall be usable for reading and discussion without mandatory live verification. Live state shall remain authoritative for writes and known conflicts.

## Completion mirroring

Task completion with an explicitly designated Markdown mirror shall update both the live Task and its matching checkbox, then identify the next unfinished Task within the requested scope. Concurrent edits shall be preserved. Partial success shall be reported and recoverable; retries shall be idempotent.

## Onboarding

- A newcomer can connect and use an agent using only product-provided guidance.
