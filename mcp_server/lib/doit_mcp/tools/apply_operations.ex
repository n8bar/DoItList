defmodule DoitMcp.Tools.ApplyOperations do
  @moduledoc """
  Apply a raw, ordered batch of operations atomically (all-or-nothing) —
  a direct mirror of `POST /api/v1/operations`.

  This is the ONLY tool that supports `lid` (client-assigned local ids for
  forward references within the same batch — e.g. bootstrapping a new
  Initiative and its first task in one call) and multi-op batches; every
  other tool in this MCP server builds exactly one op against a real id.

  Each element of `operations` must be a JSON object matching the wire
  format:

      %{
        "op" => "add" | "update" | "remove",
        "type" => "task" | "initiative" | "comment" | "member" | "notification" | "link",
        "id" => <int, for update/remove targeting a real resource>,
        "lid" => <string, for add — a batch-local reference other later ops
                  in the SAME call can point back to>,
        "data" => <op-specific fields, matching whichever domain tool
                   documents for that op/type>
      }

  ## Referencing a `lid` from a later op — the forward-reference mechanism

  Registering a `lid` on an `add` (above) is only half of it — here's how a
  LATER op in the same batch points back to it:

    * To target the created resource itself (an `update`/`remove` on it):
      put the same string in that op's own top-level `"lid"` field instead
      of `"id"` — e.g. `%{"op" => "update", "type" => "task", "lid" => "t1",
      "data" => %{"manual_progress" => 50}}`.
    * To reference it as a RELATIONSHIP inside another op's `data`: use a
      `<field>_lid` key instead of `<field>_id` — e.g. `"parent_lid" =>
      "t1"` instead of `"parent_id"` (a task's parent), `"initiative_lid" =>
      "i"` (a task's Initiative), `"source_lid"`/`"target_lid"` (a link's
      endpoints), `"task_lid"` (a comment's task).

  A lid only resolves to an EARLIER op's `add` of the matching `type` —
  never a later or wrong-type one. Worked example — bootstrap an Initiative
  and its first task, then mark it done, in one call:

      [
        %{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "New project"}},
        %{"op" => "add", "type" => "task", "lid" => "t1", "data" => %{"initiative_lid" => "i", "title" => "First task"}},
        %{"op" => "update", "type" => "task", "lid" => "t1", "data" => %{"done" => true}}
      ]

  This tool is a pure pass-through — the caller is responsible for building
  each op object correctly per the wire format above; no reshaping happens
  here.
  """

  use Anubis.Server.Component, type: :tool

  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:operations, {:list, :map}, required: true)
  end

  def execute(params, frame) do
    params.operations
    |> Client.operations()
    |> then(&ToolResult.reply_batch(frame, &1))
  end
end
