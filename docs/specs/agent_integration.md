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

Every request carries `Authorization: Bearer doit_pat_…`. Tokens are issued and revoked on the account page. The server keeps only a hash, so a lost token is replaced, never recovered.

### Errors

| Code | Means | What to do |
|---|---|---|
| 401 | no usable token | issue a new one |
| 403 | role too low for this action | ask the Initiative's owner |
| 404 | missing, or invisible to you | check agent access |
| 429 | over 120 requests a minute | wait, then retry |

An [Initiative with agent access off](#safety-and-authorization) reads as not found, never forbidden. The API does not confirm that a record you cannot reach exists.

### The operations envelope

`POST /api/v1/operations` applies an ordered list all or nothing, 150 at most. A record you create can carry a `lid` that later operations in the same batch point at; a lid used before it is defined fails the request. Resending with the same `Idempotency-Key` replays the stored result instead of applying twice.

```json
{"operations": [
  {"op": "add", "type": "task", "lid": "epic", "data": {"initiative_id": 12, "title": "Ship the parser"}},
  {"op": "add", "type": "task", "data": {"parent_lid": "epic", "title": "Write the lexer"}}
]}
```

<!-- generated: DoItWeb.Api.Operations -->
| Op | Type | Data keys |
|---|---|---|
| add | task | assignee_id, description, done, initiative, initiative_id, initiative_lid, manual_progress, numbered_title, parent, parent_id, parent_lid, position, priority, status, title |
| update | task | assignee_id, co_assignee_ids, description, done, expected_version, manual_progress, numbered_title, parent, parent_id, parent_lid, position, priority, reorder, title |
| remove | task | expected_version |
| add | initiative | auto_promote_co_assignees, description, index_style, name, progress_calc, subtitle, viewer_plus |
| update | initiative | auto_promote_co_assignees, description, expected_version, index_style, name, owner_id, progress_calc, state, subtitle, viewer_plus |
| add | comment | body, task, task_id, task_lid |
| update | comment | body |
| remove | comment | — |
| add | member | initiative, initiative_id, initiative_lid, role, user_id |
| update | member | initiative, initiative_id, initiative_lid, role, user_id |
| remove | member | initiative, initiative_id, initiative_lid, user_id |
| update | notification | all, read |
| add | link | source, source_id, source_lid, target, target_id, target_lid |
| remove | link | source, source_id, source_lid, target, target_id, target_lid |
<!-- /generated: DoItWeb.Api.Operations -->

<!-- generated: DoItWeb.Api.Serializer -->
| Shape | Purpose |
|---|---|
| initiative_summary | An Initiative list item (`GET /api/v1/initiatives`) |
| initiative_tree | The whole-Initiative tree response body (`GET /api/v1/initiatives/:id`) |
| initiative_url | The Initiative's web URL |
| task_ref | The task → Initiative resolver body (`GET /api/v1/tasks/:id`) |
| activity_event | One activity event (`GET /api/v1/initiatives/:id/activity`) |
| member | One Initiative member with their role (`GET /api/v1/initiatives/:id/members`) |
| comment | One comment, including the tombstone form for a soft-deleted comment |
<!-- /generated: DoItWeb.Api.Serializer -->

### Read-only and writable fields

`progress` is the rolled-up number the server maintains, and it is read-only. Write `manual_progress`, and only on a leaf; a parent's progress comes from its children.

## MCP server

<!-- generated: DoitMcp.Server -->
| Tool | Purpose |
|---|---|
| add_comment | Add one comment to a task |
| add_link | Add one directed task-to-task cross-reference link |
| apply_operations | Atomically apply up to 150 ordered operations |
| complete_task | Mark one task done or not done |
| create_initiative | Create one Initiative |
| create_task | Create one task |
| delete_comment | Delete one comment |
| delete_task | Soft-delete one task and its entire subtree; never delete included descendants separately |
| edit_comment | Edit one comment's body |
| get_initiative_activity | Read one Initiative's activity |
| get_initiative_members | Read one Initiative's members and roles |
| get_initiative_tree | Read one Initiative's full task tree with live index labels |
| get_me | Read the acting user's identity and account details |
| get_task_comments | Read one task's comments, including soft-delete tombstones |
| import_text | Import one document into a Task tree |
| list_initiatives | List the acting user's Initiatives |
| move_task | Move one task to a new parent and/or sibling position |
| remove_link | Remove one directed task-to-task cross-reference link, identified by its exact `source_task_id` and `target_task_id` pair |
| set_initiative_state | Change one Initiative's lifecycle state |
| update_initiative | Update one Initiative's name, description, subtitle, progress calculation, task numbering, co-assignee auto-promotion, or viewer+ access |
| update_task | Update one task's title, description, priority, assignee, or manual progress |
<!-- /generated: DoitMcp.Server -->

### Tools and the endpoints behind them

Every write tool is one operation in a batch of one, posted to the operations endpoint; `apply_operations` passes a whole batch through. Read tools map to the read endpoints one for one. Anything the tools do not cover, the API still does.

### Setup

Paste the block for your client. The account page shows it with your token.

<!-- generated: DoItWeb.AgentConnect -->
#### Claude Code

```sh
claude mcp add --transport http doitlist https://doitlist.app/mcp/ --header "Authorization: Bearer doit_pat_YOUR_TOKEN"
```

#### Codex

```sh
export DOITLIST_API_TOKEN='doit_pat_YOUR_TOKEN'
echo "export DOITLIST_API_TOKEN='doit_pat_YOUR_TOKEN'" >> ~/.bashrc   # or your shell's profile
codex mcp add doitlist --url https://doitlist.app/mcp/ --bearer-token-env-var DOITLIST_API_TOKEN
```

```powershell
$env:DOITLIST_API_TOKEN = 'doit_pat_YOUR_TOKEN'
setx DOITLIST_API_TOKEN 'doit_pat_YOUR_TOKEN'   # persists it for new shells; restart a running terminal or editor so its shells see it
codex mcp add doitlist --url https://doitlist.app/mcp/ --bearer-token-env-var DOITLIST_API_TOKEN
```

#### Hermes Agent

```sh
hermes mcp add doitlist --url https://doitlist.app/mcp/ --auth header
echo "MCP_DOITLIST_API_KEY=doit_pat_YOUR_TOKEN" >> ~/.hermes/.env
```

```powershell
hermes mcp add doitlist --url https://doitlist.app/mcp/ --auth header
Add-Content -Path ~/.hermes/.env -Value 'MCP_DOITLIST_API_KEY=doit_pat_YOUR_TOKEN' -Encoding utf8
```

#### Scripted client (doitlist.py)

```sh
export DOITLIST_API_URL='https://doitlist.app'
export DOITLIST_API_TOKEN='doit_pat_YOUR_TOKEN'
echo "export DOITLIST_API_URL='https://doitlist.app'" >> ~/.bashrc   # or your shell's profile
echo "export DOITLIST_API_TOKEN='doit_pat_YOUR_TOKEN'" >> ~/.bashrc   # or your shell's profile
python3 --version   # 3.8 or newer
```

```powershell
$env:DOITLIST_API_URL = 'https://doitlist.app'
$env:DOITLIST_API_TOKEN = 'doit_pat_YOUR_TOKEN'
setx DOITLIST_API_URL 'https://doitlist.app'
setx DOITLIST_API_TOKEN 'doit_pat_YOUR_TOKEN'
py -3 --version   # if missing: winget install --id Python.Python.3.13 -e
```
<!-- /generated: DoItWeb.AgentConnect -->

### Walkthrough

Import a plan, tick a Task against it, read the tree back.

```sh
doitlist.py import PLAN.md --as "Q3 plan" --preview   # then apply by the preview's id
doitlist.py done %<412> --mirror PLAN.md --section "Parser"
doitlist.py tree 12 --depth 2
```

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

A mirror is a [Markdown file standing in for an Initiative](#shared-work). Its import writes each Task's `%<id>` onto the source line, so [completions](#completion-mirroring) read the file, not the tree. Live reads are for writes and drift.

### Import format

Headings are branches. List items are Tasks, nested by indent. A ticked box imports done. [Order and wording stay as written](#import-fidelity); a trailing `%<id>` is stripped.

### Recovery

A write whose outcome is unknown prints the command that settles it. Run it first; the same key replays rather than reapplying.
