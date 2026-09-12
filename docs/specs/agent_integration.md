# Agent Integration

_Status: Approved._

This specification defines durable behavior for AI agents interacting with Do It List.

The sections above the surfaces are the promises. Below them, each surface documents how it keeps those promises. Blocks between `<!-- generated: SOURCE -->` and `<!-- /generated: SOURCE -->` are written by `mix doit.docs.gen` from the code; hand-edits inside a fence are lost on the next run.

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

## HTTP API

### Authentication

### Errors

### The operations envelope

<!-- generated: DoItWeb.Api.Operations -->
| Op | Type | Data keys | Errors |
|---|---|---|---|
| add | task | assignee_id, description, done, initiative, initiative_id, initiative_lid, manual_progress, numbered_title, parent, parent_id, parent_lid, position, priority, status, title | unprocessable_entity, not_found, forbidden, bad_reference |
| update | task | assignee_id, co_assignee_ids, description, done, expected_version, manual_progress, numbered_title, parent, parent_id, parent_lid, position, priority, reorder, title | unprocessable_entity, not_found, forbidden, bad_reference, conflict |
| remove | task | expected_version | unprocessable_entity, not_found, forbidden, bad_reference, conflict |
| add | initiative | auto_promote_co_assignees, description, index_style, name, progress_calc, subtitle, viewer_plus | unprocessable_entity, bad_reference |
| update | initiative | auto_promote_co_assignees, description, expected_version, index_style, name, owner_id, progress_calc, state, subtitle, viewer_plus | unprocessable_entity, not_found, forbidden, bad_reference, conflict, irreversible_op |
| add | comment | body, task, task_id, task_lid | unprocessable_entity, not_found, forbidden, bad_reference |
| update | comment | body | unprocessable_entity, not_found, forbidden, bad_reference |
| remove | comment | — | unprocessable_entity, not_found, forbidden, bad_reference |
| add | member | initiative, initiative_id, initiative_lid, role, user_id | unprocessable_entity, not_found, forbidden, bad_reference, irreversible_op |
| update | member | initiative, initiative_id, initiative_lid, role, user_id | unprocessable_entity, not_found, forbidden, bad_reference, irreversible_op |
| remove | member | initiative, initiative_id, initiative_lid, user_id | unprocessable_entity, not_found, forbidden, bad_reference |
| update | notification | all, read | unprocessable_entity, not_found, forbidden |
| add | link | source, source_id, source_lid, target, target_id, target_lid | unprocessable_entity, not_found, forbidden, bad_reference |
| remove | link | source, source_id, source_lid, target, target_id, target_lid | unprocessable_entity, not_found, forbidden, bad_reference |
<!-- /generated: DoItWeb.Api.Operations -->

<!-- generated: DoItWeb.Api.Serializer -->
| Shape | Purpose |
|---|---|
| initiative_summary | An Initiative list item (`GET /api/v1/initiatives`). |
| initiative_tree | The whole-Initiative tree response body (`GET /api/v1/initiatives/:id`). |
| initiative_url | The Initiative's web URL — the operator-facing handle (m03.04 2.1.3) — composed from the endpoint's public URL config via verified routes. |
| task_ref | The task → Initiative resolver body (`GET /api/v1/tasks/:id`). |
| activity_event | One activity event (`GET /api/v1/initiatives/:id/activity`). |
| member | One Initiative member with their role (`GET /api/v1/initiatives/:id/members`). |
| comment | One comment, including the tombstone form for a soft-deleted comment. |
<!-- /generated: DoItWeb.Api.Serializer -->

### Read-only and writable fields

## MCP server

<!-- generated: DoitMcp.Server -->
| Tool | Purpose |
|---|---|
| add_comment | Add one comment to a task. |
| add_link | Add one directed task-to-task cross-reference link. |
| apply_operations | Atomically apply up to 150 ordered operations. |
| complete_task | Mark one task done or not done. |
| create_initiative | Create one Initiative — the top-level container that owns a task tree. |
| create_task | Create one task. |
| delete_comment | Delete one comment. |
| delete_task | Soft-delete one task and its entire subtree; never delete included descendants separately. |
| edit_comment | Edit one comment's body. |
| get_initiative_activity | Read one Initiative's activity. |
| get_initiative_members | Read one Initiative's members and roles. |
| get_initiative_tree | Read one Initiative's full task tree with live index labels. |
| get_me | Read the acting user's identity and account details. |
| get_task_comments | Read one task's comments, including soft-delete tombstones. |
| import_text | Import one document into a Task tree. |
| list_initiatives | List the acting user's Initiatives. |
| move_task | Move one task to a new parent and/or sibling position — reorder, reparent, promote, and demote are all this tool. |
| remove_link | Remove one directed task-to-task cross-reference link, identified by its exact `source_task_id` and `target_task_id` pair. |
| set_initiative_state | Change one Initiative's lifecycle state. |
| update_initiative | Update one Initiative's name, description, subtitle, progress calculation, task numbering, co-assignee auto-promotion, or viewer+ access. |
| update_task | Update one task's title, description, priority, assignee, or manual progress. |
<!-- /generated: DoitMcp.Server -->

### Tools and the endpoints behind them

### Setup

### Walkthrough

## Scripted client

<!-- generated: scripts/doitlist.py -->
| Verb | Args | Options | Purpose |
|---|---|---|---|
| list | — | — | list the Initiatives you can reach |
| tree | initiative | --under, --depth | print an Initiative's outline |
| comments | task | — | print a Task's comments |
| activity | initiative | --task, --limit | print an Initiative's activity |
| add | parent title | --out, --numbered | add a Task under a parent |
| done | task | --out, --reopen, --mirror, --section, --initiative | complete a Task |
| progress | task percent | --out | set a Task's Progress |
| move | task parent [position] | --out | reparent or reorder a Task |
| comment | task text | --out | comment on a Task |
| retitle | task title | --out, --numbered | change a Task's title |
| describe | task text | --out | set a Task's description |
| delete | task | --out | delete a Task (and its subtree) |
| import | file | --out, --into, --under, --section, --as, --preview, --no-ids | import a document as a Task tree |
| diff | file initiative | --out, --under | compare a document with an existing Initiative |
| retry | [key] | --out | resend writes whose outcome is unknown |
<!-- /generated: scripts/doitlist.py -->

### The mirror workflow

### Import format

### Recovery
