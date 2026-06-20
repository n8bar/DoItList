defmodule DoItWeb.AssignedActions do
  @moduledoc """
  Shared Assigned-to-Me toggle handling (m02.08 worklist 1) so the full
  `/assigned` page (item 1.1) and the ultrawide index right pane (item 1.3)
  behave identically.

  The two ephemeral reveals (completed, archived/hidden) live in socket assigns
  and reset each visit; Group-by-Initiative (item 1.6) persists to
  `user_preferences` so it follows the account, like the index sort (m02.04
  §2.6). Each toggle re-streams the list from the query.
  """
  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [stream: 4]

  alias DoIt.Accounts
  alias DoItWeb.AssignedComponents

  @stream_name :assigned_tasks

  @doc """
  Seed the Assigned-to-Me assigns + stream on mount. Reveals start off;
  Group-by reads from the account.
  """
  def assign_initial(socket, user) do
    prefs = Accounts.get_preferences(user)

    socket
    |> assign(:show_completed, false)
    |> assign(:show_archived_hidden, false)
    |> assign(:group_by_initiative, prefs.assigned_group_by_initiative)
    |> restream(user)
  end

  @doc "Toggle the ephemeral 'show completed' reveal and re-stream."
  def toggle_completed(socket, user) do
    socket
    |> assign(:show_completed, !socket.assigns.show_completed)
    |> restream(user)
  end

  @doc "Toggle the ephemeral 'show archived & hidden' reveal and re-stream."
  def toggle_archived_hidden(socket, user) do
    socket
    |> assign(:show_archived_hidden, !socket.assigns.show_archived_hidden)
    |> restream(user)
  end

  @doc "Toggle the persistent Group-by-Initiative pref (account-following) and re-stream."
  def toggle_group_by(socket, user) do
    next = !socket.assigns.group_by_initiative
    {:ok, _} = Accounts.update_preferences(user, %{"assigned_group_by_initiative" => next})

    socket
    |> assign(:group_by_initiative, next)
    |> restream(user)
  end

  @doc "Re-fetch with current reveal flags and reset the stream + count/empty assigns."
  def restream(socket, user) do
    tasks = AssignedComponents.fetch_assigned(user, socket.assigns)

    socket
    |> assign(:assigned_count, length(tasks))
    |> assign(:assigned_empty?, tasks == [])
    |> stream(@stream_name, tasks, reset: true)
  end

  def stream_name, do: @stream_name
end
