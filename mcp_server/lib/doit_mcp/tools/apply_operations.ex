defmodule DoitMcp.Tools.ApplyOperations do
  @moduledoc """
  Atomically apply up to 150 ordered operations. Always use this tool for multi-operation passes and `lid` references; every other tool submits one operation against a real id.

  Always batch the whole pass, including bulk completions, comments, and edits. Never loop per-operation tools. If the pass exceeds 150 operations, split it into batches filled toward the cap. Reply with `index` and `title`, never ids.

  ## Wire format

  Each operation is a JSON object with these fields:

      {
        "op": "add" | "update" | "remove",
        "type": "task" | "initiative" | "comment" | "link",
        "id": <real id for updating or removing an existing resource>,
        "lid": <batch-local id assigned by an add or used by a later same-batch update/remove to target that add>,
        "data": <fields documented by the corresponding domain tool>
      }

  ## Batch-local references — `lid`

  Assign a unique `lid` to an add when later operations in the same batch must reference it.

    * To update or remove an earlier add, put its `lid` in the later operation's top-level `"lid"` instead of `"id"`.
    * To use an earlier add in a relationship, replace `<field>_id` with `<field>_lid`, such as `parent_lid`, `initiative_lid`, `task_lid`, `source_lid`, or `target_lid`.
    * For references between tasks added in the same batch, always add both tasks before their link operations, then use `source_lid` and `target_lid`. For mutual references, add one link per direction.

  A `lid` always resolves to an earlier add of the required type. Never reference a later add, reuse a `lid`, or carry one across batches. Across batches, always use the returned real ids.

  A `lid` never replaces the numeric id inside a `%<task_id>` text reference. When new task text must reference another new task, add the tasks first and update the text after their real ids return.

  ## Completion — `done`

  Always set `done` in the task's add or update that performs the completion. Never add a task and complete it with a second operation.

  ## Conditional updates — `expected_version`

  For every task or Initiative update, always pass the latest read's `version` as `expected_version` unless overwriting any intervening change is acceptable. A stale version rolls back the entire batch and returns the current record under `current`; always reconcile that record before retrying.

  ## Safe retries — `idempotency_key`

  When a batch may be retried after a timeout or lost response, always give it a unique `idempotency_key`. Retry only the unchanged batch with the same key; the server replays a committed response instead of applying it again. Never reuse the key for a different batch.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:operations, {:list, :map}, required: true)
    field(:idempotency_key, :string, required: false)
  end

  def execute(params, frame) do
    params.operations
    |> Client.operations(idempotency_key: Map.get(params, :idempotency_key))
    |> then(&ToolResult.reply_batch(frame, &1))
  end
end
