defmodule DoitMcp.Tools.ImportText do
  @moduledoc """
  Import one document into a Task tree. Always use this tool for a list or document the user pastes or uploads, and for a typed list of several items; use `apply_operations` only for individual changes to an existing tree. Send one call per document.

  Always pass the source text verbatim in `text` — never summarized, retyped, reformatted, or reordered. Pass `filename` when the document came from a file.

  Target exactly one of:

    * `initiative_name` — create a new Initiative;
    * `initiative_id` — an existing Initiative, optionally under `parent_task_id`.

  Applies by default, returning the title, counts, outline, and the Initiative's `url`. Reply with the outline's labels and titles, and the Initiative `url`.

  `preview: true` writes nothing and returns the same outline, a diff against an existing target, and a `preview_id`; to apply it, pass `preview_id` instead of `text` (one of the two is required).

  Re-applying the same text to the same target replays the first result and creates nothing.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, ToolResult}

  schema do
    field(:text, :string, required: false)
    field(:preview_id, :string, required: false)
    field(:filename, :string, required: false)
    field(:initiative_name, :string, required: false)
    field(:initiative_id, :integer, required: false)
    field(:parent_task_id, :integer, required: false)
    field(:preview, :boolean, required: false)
  end

  def execute(params, frame) do
    case body(params) do
      {:ok, body} ->
        body
        |> put_present("filename", Map.get(params, :filename))
        |> put_present("preview", Map.get(params, :preview))
        |> then(&Client.post("/api/v1/imports", &1))
        |> then(&ToolResult.reply_json(frame, &1))

      {:error, message} ->
        {:reply, Response.error(Response.tool(), message), frame}
    end
  end

  # A `preview_id` applies a stored preview — its source and target are the
  # server's, so no target is required here (m03.04 6.7). Otherwise `text` goes
  # to the wire exactly as it arrived — the parser owns every decision about the
  # document, so trimming or reflowing here would silently change the tree the
  # user is importing.
  defp body(%{preview_id: id} = params) when is_binary(id) do
    {:ok, put_present(%{"preview_id" => id}, "text", Map.get(params, :text))}
  end

  defp body(%{text: text} = params) when is_binary(text) do
    with {:ok, target} <- target(params) do
      {:ok, %{"text" => text, "target" => target}}
    end
  end

  defp body(_params),
    do: {:error, "Pass text (the document to import) or preview_id (from a preview)."}

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
