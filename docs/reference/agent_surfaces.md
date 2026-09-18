# Agent Surfaces

How to reach Do It List as an agent: the HTTP API, the MCP server, and the scripted client. The promises these surfaces keep are in [`agent_integration.md`](../specs/agent_integration.md), stated once there and linked from here.

Blocks between `<!-- generated: SOURCE -->` and `<!-- /generated: SOURCE -->` are written by `mix doit.docs.gen` from the code. Hand-edits inside a fence are lost on the next run.

## HTTP API

### Authentication

Every request carries `Authorization: Bearer doit_pat_…`. Tokens are issued and revoked on the account page. The server keeps only a hash, so a lost token is replaced, never recovered.

The browser client has its own private surface under `/app/api`, authenticated by the web session and sharing this API's operations engine and read serializers. A bearer token never works there; a session never works on `/api/v1`. The same session also authenticates its live socket at `/socket`, which pushes change notices for an Initiative the user may already read, and carries a `user:<id>` channel — joinable only as yourself — whose `notification` event is one of the user's own notifications, already worded and linked. That surface also answers `GET /app/api/notifications` with the user's recent notifications and unread count; marking them read is the ordinary `update notification` operation. It answers two more Initiative reads: `/members`, with roles, and `/history`, what this user can undo and redo. Its `initiative:<id>` channel carries selection presence too — a client sends `select` with a task id or null, and gets `presence_state` on join and `presence_diff` after, so each route sees the other's people. It is not an agent surface — agents use the endpoints below.

### Endpoints

<!-- generated: DoItWeb.Router -->
| Method | Path | Purpose |
|---|---|---|
| GET | /api/v1/me | Who the token belongs to |
| GET | /api/v1/initiatives | List the Initiatives the acting user belongs to |
| GET | /api/v1/initiatives/:id | The whole nested Initiative tree in one response |
| GET | /api/v1/initiatives/:id/activity | One Initiative's activity, newest first |
| GET | /api/v1/initiatives/:id/members | The Initiative's members with their roles |
| GET | /api/v1/initiatives/:id/task_count | How many Tasks an Initiative has |
| GET | /api/v1/initiatives/:id/tasks/:task_id/comments | A task's comments, including tombstones for soft-deleted ones |
| GET | /api/v1/tasks/:id | Which Initiative a bare task id belongs to |
| POST | /api/v1/operations | Apply an ordered batch of write operations, all or nothing |
| POST | /api/v1/imports | Import a source document as a Task tree, or preview it |
<!-- /generated: DoItWeb.Router -->

### Errors

| Code | Means | What to do |
|---|---|---|
| 401 | no usable token | issue a new one |
| 403 | role too low for this action | ask the Initiative's owner |
| 404 | missing, or invisible to you | check agent access |
| 422 | the batch was rejected | read `results` for the failing index |
| 429 | over 120 requests a minute | wait the `Retry-After` seconds |

An [Initiative with agent access off](../specs/agent_integration.md#safety-and-authorization) reads as not found, never forbidden. The API does not confirm that a record you cannot reach exists.

### The operations envelope

`POST /api/v1/operations` applies an ordered list all or nothing, 150 at most. A record you create can carry a `lid` that later operations in the same batch point at; a lid used before it is defined fails the request. Resending with the same `Idempotency-Key` replays the stored result instead of applying twice.

```json
{"operations": [
  {"op": "add", "type": "task", "lid": "epic", "data": {"initiative_id": 12, "title": "Ship the parser"}},
  {"op": "add", "type": "task", "data": {"parent_lid": "epic", "title": "Write the lexer"}},
  {"op": "update", "type": "task", "id": 412, "data": {"manual_progress": 50}}
]}
```

`add history` reverses the Initiative's newest reversible action: `data` takes an `initiative_id` and an `action` of `undo` or `redo`. The stack is shared, and reversing is role-gated like the original write, so an action you may not reverse reads as nothing to undo. The result names the kind it reversed and carries a delta: `upserts` for the tasks still live, each with its slot and description, `removed` for the ones gone, and `refetch` when the reversal changed something a delta can't carry, like a comment.

`update task` with `ids` in place of `id` moves many tasks as one block: `data` carries `parent_id` (or `parent_lid`) and an optional `position`, nothing else. The tasks land under that parent in list order, from `position` or the top when omitted, as one undo step and one activity line. The result's `id` is the first moved task and `records` carries every moved record in order. Every listed task must be reachable with edit rights and share the destination's Initiative; one bad entry fails the op with nothing moved. Both `id` and `ids`, an empty list, or a non-integer entry is rejected at `ids`.

`update task` with `sort_mode` and/or `sort_reverse` sets how that branch orders its children: `sort_mode` is one of `manual`, `alphabetical`, `completion`, `priority`, `created`, `updated`, or `null` to inherit the nearest ancestor's; `sort_reverse` flips the direction; a key left out keeps its current value. `cascade_sort: true` makes every descendant branch inherit, so the whole subtree follows this branch from then on; given with a mode it sets first, then cascades, as one op and one activity line each. The result's `records` carry the target and every branch the cascade changed, each with its `sort_mode` and `sort_reverse`; read the tree for the children's new order.

`update initiative` with `position` puts that Initiative at a 0-based slot in your own Manual order of the index — the list the app shows under Sort: Manual. It is your view alone: any member may set it, nobody else's order moves, and the Initiative's `version` does not change. Rows you have never placed sit after the placed ones, owners' first then most recently updated; a slot past the end lands last. The result carries the resolved `sort_order` and `order`, the full id list as it now reads. `position` travels alone — no content field in the same op.

A response carries `results`, one entry per operation, in order. Each names a `status` — `ok`, `error`, or `not_applied` — and a failure's `pointer` names the field at fault. One failure rolls the whole batch back, so every other entry reads `not_applied`.

<!-- generated: DoItWeb.Api.Operations -->
| Op | Type | Data keys |
|---|---|---|
| add | task | assignee_id, description, done, initiative, initiative_id, initiative_lid, manual_progress, numbered_title, parent, parent_id, parent_lid, position, priority, status, title |
| update | task | assignee_id, cascade_sort, co_assignee_ids, description, done, expected_version, manual_progress, numbered_title, parent, parent_id, parent_lid, position, priority, reorder, sort_mode, sort_reverse, title |
| remove | task | expected_version |
| add | initiative | auto_promote_co_assignees, description, index_style, name, progress_calc, subtitle, viewer_plus |
| update | initiative | auto_promote_co_assignees, description, expected_version, index_style, name, position, progress_calc, state, subtitle, viewer_plus |
| add | comment | body, task, task_id, task_lid |
| update | comment | body |
| remove | comment | — |
| add | member | initiative, initiative_id, initiative_lid, role, user_id |
| update | member | initiative, initiative_id, initiative_lid, role, user_id |
| remove | member | initiative, initiative_id, initiative_lid, user_id |
| update | notification | all, read |
| add | link | source, source_id, source_lid, target, target_id, target_lid |
| remove | link | source, source_id, source_lid, target, target_id, target_lid |
| add | history | action, initiative_id |
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
| comment | One comment, tombstoned when soft-deleted (`GET /api/v1/initiatives/:id/tasks/:task_id/comments`) |
<!-- /generated: DoItWeb.Api.Serializer -->

### Read-only and writable fields

An Initiative list item also carries its `description` and `created_at`, so a list can be shown and ordered without reading each tree. `progress` is the rolled-up number the server maintains; writing it is refused. Leaves take `manual_progress`; branches don't — a branch's progress comes from its children. A task node also names the `sort_mode` and `sort_reverse` its children are ordered by; `null` inherits.


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
| move | task parent [position] | --out | reparent or reorder Tasks |
| comment | task text | --out | comment on a Task |
| retitle | task title | --out, --numbered | change a Task's title |
| describe | task text | --out | set a Task's description |
| delete | task | --out | delete a Task (and its subtree) |
| import | file | --out, --into, --under, --section, --as, --preview, --no-ids | import a document as a Task tree |
| diff | file initiative | --out, --under | compare a document with an existing Initiative |
| retry | [key] | --out | resend writes whose outcome is unknown |
<!-- /generated: scripts/doitlist.py -->

`move` takes one Task or a comma-separated list: `move %12,%15,%9 %7 0` lands the three under Task 7 in that order as one write. A single Task still sends its `expected_version`; a list cannot.

### Walkthrough

Import a plan, tick a Task against it, read the tree back.

```sh
doitlist.py import PLAN.md --as "Q3 plan" --preview   # then re-run without --preview to apply
doitlist.py done %<412> --mirror PLAN.md --section "Parser" --initiative 12
doitlist.py tree 12 --depth 2
```

### The mirror workflow

A mirror is a [Markdown file standing in for an Initiative](../specs/agent_integration.md#shared-work). Its import writes each Task's `%<id>` onto the source line, so [completions](../specs/agent_integration.md#completion-mirroring) read the file, not the tree. It writes nothing else, so name the Initiative with `--initiative` unless the file already links it. Live reads are for writes and drift.

### Import format

Headings are branches. List items are Tasks, nested by indent. A ticked box imports done. [Order and wording stay as written](../specs/agent_integration.md#import-fidelity); a trailing `%<id>` is stripped.

### Recovery

A write whose outcome is unknown prints the command that settles it. Run it first; the same key replays rather than reapplying.


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
| move_task | Move one task, or many as one block, to a new parent and/or sibling position; reorder, reparent, promote, and demote are all this tool |
| remove_link | Remove one directed task-to-task cross-reference link, identified by its exact `source_task_id` and `target_task_id` pair |
| set_initiative_state | Change one Initiative's lifecycle state |
| update_initiative | Update one Initiative's name, description, subtitle, progress calculation, task numbering, co-assignee auto-promotion, or viewer+ access |
| update_task | Update one task's title, description, priority, assignee, or manual progress |
<!-- /generated: DoitMcp.Server -->

### Tools and the endpoints behind them

Every write tool is one operation in a batch of one, posted to the operations endpoint; `apply_operations` passes a whole batch through. Read tools map to the read endpoints one for one. Anything the tools do not cover, the API still does.

### Setup

Paste the block for your client, in the variant for your shell. Immediately after minting only, the account page shows it with your token.

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
echo "MCP_DOITLIST_API_KEY=doit_pat_YOUR_TOKEN" >> ~/.hermes/.env
hermes mcp add doitlist --url https://doitlist.app/mcp/ --auth header
```

```powershell
Add-Content -Path "$env:LOCALAPPDATA\hermes\.env" -Value 'MCP_DOITLIST_API_KEY=doit_pat_YOUR_TOKEN' -Encoding utf8
hermes mcp add doitlist --url https://doitlist.app/mcp/ --auth header
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

Ask your agent for these in its own chat; the tools it reaches for are named beside each.

1. Confirm the connection — `get_me`. It answers only with a working token.
2. Import a plan into a new Initiative — `import_text`.
3. Mark one Task done — `get_initiative_tree` to find it, then `complete_task`.
4. Read the tree back — `get_initiative_tree`.

Nothing here runs the scripted client; an MCP agent calls tools, never `doitlist.py`.
