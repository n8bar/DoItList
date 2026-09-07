defmodule DoitMcp.Tools.ImportText do
  @moduledoc """
  Import one document into a Task tree. Always use this tool for a list or document the user pastes or uploads, and for a typed list of several items; use `apply_operations` only for individual changes to an existing tree. Send one call per document.

  Always pass the source text verbatim in `text` — never summarized, retyped, reformatted, or reordered. Pass `filename` when the document came from a file.

  Target exactly one of:

    * `initiative_name` — create a new Initiative;
    * `initiative_id` — an existing Initiative, optionally under `parent_task_id`.

  Applies by default, returning the title, counts, outline, and the Initiative's `url`. Always give the user that `url`, never the raw id.

  `preview: true` writes nothing and returns the same outline, plus a diff against an existing target.

  Re-applying the same text to the same target replays the first result and creates nothing.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:text, :string, required: true)
    field(:filename, :string, required: false)
    field(:initiative_name, :string, required: false)
    field(:initiative_id, :integer, required: false)
    field(:parent_task_id, :integer, required: false)
    field(:preview, :boolean, required: false)
  end

  def execute(params, frame) do
    case target(params) do
      {:ok, target} ->
        # `text` goes to the wire exactly as it arrived — the parser owns every
        # decision about the document, so trimming or reflowing here would
        # silently change the tree the user is importing.
        %{"text" => params.text, "target" => target}
        |> put_present("filename", Map.get(params, :filename))
        |> put_present("preview", Map.get(params, :preview))
        |> then(&Client.post("/api/v1/imports", &1))
        |> then(&ToolResult.reply_json(frame, &1))

      {:error, message} ->
        {:reply, Response.error(Response.tool(), message), frame}
    end
  end

  # The target rules are the endpoint's, enforced here so a violation costs no
  # round trip and names the rule it broke.
  defp target(params) do
    name = Map.get(params, :initiative_name)
    id = Map.get(params, :initiative_id)
    parent = Map.get(params, :parent_task_id)

    cond do
      is_nil(name) == is_nil(id) ->
        {:error,
         "Pass exactly one target: initiative_name to create a new Initiative, " <>
           "or initiative_id to import into an existing one."}

      not is_nil(parent) and is_nil(id) ->
        {:error, "parent_task_id requires initiative_id; it names a Task in that Initiative."}

      is_nil(id) ->
        {:ok, %{"initiative_name" => name}}

      true ->
        {:ok, put_present(%{"initiative_id" => id}, "parent_task_id", parent)}
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
