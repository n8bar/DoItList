defmodule DoitMcp.Resources.InitiativeActivity do
  @moduledoc """
  Read the unfiltered first page of one Initiative's activity. This resource accepts only the Initiative ID. Always use `get_initiative_activity` when subtree filtering or pagination is required.
  """

  use Anubis.Server.Component,
    type: :resource,
    uri_template: "doitlist://initiatives/{id}/activity"

  alias DoitMcp.{Client, ResourceResult}

  @impl true
  def read(%{"params" => %{"id" => id} = vars}, frame) do
    query =
      [
        task_id: Map.get(vars, "task_id"),
        limit: Map.get(vars, "limit"),
        offset: Map.get(vars, "offset")
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    frame |> ResourceResult.reply(Client.get("/api/v1/initiatives/#{id}/activity", query))
  end
end
