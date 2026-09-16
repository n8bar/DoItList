defmodule DoItWeb.InitiativeChannel do
  @moduledoc """
  One Initiative's live channel (m04.01 item 1.5), topic `"initiative:<id>"`.

  Joining is authorized by the **same** gate the browser's read surface uses —
  `DoItWeb.Api.Authz.fetch_initiative/4` with `require_agent_access: false`, the
  flag `DoItWeb.Client.InitiativeController` passes — so anything a member can
  `GET /app/api/initiatives/:id` they can also watch, and nothing else. An
  unknown id and an Initiative the user can't see are told apart exactly as the
  HTTP surface tells them apart.

  The channel topic *is* the PubSub topic the contexts already broadcast on
  (`DoIt.Tasks.subscribe/1`'s topic, and the one `DoIt.Initiatives` sends
  `:members_changed` on), so Phoenix's own channel subscription delivers those
  messages here — subscribing again would only duplicate every event.

  Every change collapses to ONE client event, `"changed"`, carrying the kind and
  the id that moved. There is no tree payload: Arc 3 defines the delta envelope,
  and until it does the honest thing is to tell the client *that* something
  changed and let it refetch. Messages this arc has no client story for
  (`:initiative_updated`, presence, chat) are ignored rather than guessed at.
  """
  use DoItWeb, :channel

  alias DoItWeb.Api.Authz

  @kinds [:task_created, :task_updated, :task_moved, :task_deleted, :members_changed]

  @impl true
  def join("initiative:" <> id, _params, socket) do
    user = socket.assigns.current_user

    case Authz.fetch_initiative(user, id, :view, require_agent_access: false) do
      {:ok, initiative} ->
        {:ok, %{initiative_id: initiative.id}, assign(socket, :initiative_id, initiative.id)}

      {:error, :forbidden} ->
        {:error, %{reason: "forbidden"}}

      {:error, :not_found} ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_info({kind, id}, socket) when kind in @kinds do
    push(socket, "changed", %{kind: Atom.to_string(kind), id: id})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
