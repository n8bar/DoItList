defmodule DoItWeb.Api.Reads do
  @moduledoc """
  The Initiative read payloads shared by the bearer API (`/api/v1`) and the
  browser client surface (`/app/api`, m04.01 worklist 5).

  The assembly — authorization, the context calls, and the `Serializer` shape —
  lives here exactly once, so both controllers are thin edges over the same
  read. The only difference between the surfaces is the `:require_agent_access`
  flag handed to `DoItWeb.Api.Authz.fetch_initiative/4`: the per-Initiative
  agent-access checkbox gates agents, not a member reading their own Initiative
  in a browser.
  """

  alias DoIt.{Initiatives, Tasks}
  alias DoIt.Accounts.User
  alias DoItWeb.Api.{Authz, Serializer}

  @doc """
  The Initiatives `user` can see, as `Serializer.initiative_summary/4` maps.

  `opts[:agent_access_only]` (default `false`) filters to agent-accessible
  Initiatives — what `/api/v1` passes; the browser passes nothing and sees the
  same set its Initiatives index does.
  """
  @spec initiative_summaries(User.t(), keyword()) :: [map()]
  def initiative_summaries(%User{} = user, opts \\ []) do
    initiatives = Initiatives.list_visible_initiatives(user, opts)
    unit_counts = Tasks.unit_counts_for_initiatives(initiatives)

    Enum.map(initiatives, fn ini ->
      Serializer.initiative_summary(
        ini,
        ini.my_role,
        ini.progress,
        Map.get(unit_counts, ini.id, 0)
      )
    end)
  end

  @doc """
  The whole nested Initiative tree, view-gated.

  Returns `{:ok, payload}`, or the `{:error, :not_found}` / `{:error,
  :forbidden}` that `Authz.fetch_initiative/4` decided — both surfaces render
  those through their own error path.
  """
  @spec initiative_tree(User.t(), term(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :forbidden}
  def initiative_tree(%User{} = user, id, opts \\ []) do
    with {:ok, initiative} <- Authz.fetch_initiative(user, id, :view, opts) do
      role = Initiatives.get_role(initiative.id, user.id)
      %{subtitle: subtitle, progress: progress} = Initiatives.header(initiative)
      tree = Tasks.initiative_task_tree(initiative.id)
      co_ids = Tasks.co_assignee_ids_for_initiative(initiative.id)
      comment_counts = Tasks.comment_counts_for_initiative(initiative.id)
      links = Tasks.list_links_for_initiative(initiative.id)

      {:ok,
       Serializer.initiative_tree(
         initiative,
         tree,
         role,
         subtitle,
         progress,
         co_ids,
         comment_counts,
         links
       )}
    end
  end
end
