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
