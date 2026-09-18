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

  A membership change is also where access can be **taken away**, so it is
  re-authorized rather than forwarded blind: a user who can no longer view the
  Initiative is told once (`"access_revoked"`) and the channel stops. Without
  that, the broadcast that evicted them would be delivered to them, and every
  change after it.

  Every other change collapses to ONE client event, `"changed"`, carrying the
  kind and the id that moved. There is no tree payload: Arc 3 defines the delta envelope,
  and until it does the honest thing is to tell the client *that* something
  changed and let it refetch. `:initiative_updated` (a render-affecting
  Initiative field, e.g. `index_style`) forwards the same way, so a numbering
  style changed elsewhere relabels an open tree rather than going stale
  (m04.02 item 7.7). Messages this arc has no client story for (chat) are
  still ignored rather than guessed at.

  ## Selection presence (m04.02 item 2.4.1)

  A joined client is tracked on `DoItWeb.Presence.initiative_topic/1` — the
  SAME topic the LiveView workspace tracks on, with the same meta — so while
  both routes are live each sees the other's members. On join the channel gets
  `"presence_state"` (everyone here now) and thereafter `"presence_diff"` as
  people come, go, and change selection. A client announces its own selection
  with `"select"`, `%{"task_id" => id | nil}`; the id only labels a row, so it
  is type-checked and otherwise taken at face value. Presence ends with the
  channel process — a leave or a dropped socket untracks it.
  """
  use DoItWeb, :channel

  alias DoItWeb.Api.Authz
  alias DoItWeb.Presence

  @kinds [
    :task_created,
    :task_updated,
    :task_moved,
    :task_deleted,
    :members_changed,
    :initiative_updated
  ]

  @impl true
  def join("initiative:" <> id, _params, socket) do
    case Authz.fetch_initiative(socket.assigns.current_user, id, :view,
           require_agent_access: false
         ) do
      {:ok, initiative} ->
        send(self(), :after_join)
        {:ok, %{initiative_id: initiative.id}, assign(socket, :initiative_id, initiative.id)}

      {:error, :forbidden} ->
        {:error, %{reason: "forbidden"}}

      {:error, :not_found} ->
        {:error, %{reason: "not_found"}}
    end
  end

  @impl true
  def handle_in("select", %{"task_id" => task_id}, socket)
      when is_integer(task_id) or is_nil(task_id) do
    Presence.update(
      self(),
      Presence.initiative_topic(socket.assigns.initiative_id),
      to_string(socket.assigns.current_user.id),
      &Map.put(&1, :task_id, task_id)
    )

    {:reply, :ok, socket}
  end

  def handle_in("select", _params, socket) do
    {:reply, {:error, %{reason: "bad_task_id"}}, socket}
  end

  # Subscribe first, then track: our own join diff arrives as the initial push
  # and already includes everyone else here, so the state we send is complete.
  @impl true
  def handle_info(:after_join, socket) do
    topic = Presence.initiative_topic(socket.assigns.initiative_id)
    Phoenix.PubSub.subscribe(DoIt.PubSub, topic)

    {:ok, _ref} =
      Presence.track(
        self(),
        topic,
        to_string(socket.assigns.current_user.id),
        Presence.selection_meta(socket.assigns.current_user, nil)
      )

    push(socket, "presence_state", Presence.list(topic))
    {:noreply, socket}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, socket) do
    push(socket, "presence_diff", diff)
    {:noreply, socket}
  end

  def handle_info({:members_changed, id}, socket) do
    case authorize(socket) do
      {:ok, _initiative} ->
        push(socket, "changed", %{kind: "members_changed", id: id})
        {:noreply, socket}

      {:error, _reason} ->
        push(socket, "access_revoked", %{initiative_id: socket.assigns.initiative_id})
        {:stop, :normal, socket}
    end
  end

  def handle_info({kind, id}, socket) when kind in @kinds do
    push(socket, "changed", %{kind: Atom.to_string(kind), id: id})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The join check, re-run. Role lookups hit the database, so this reflects the
  # membership as it stands now, not as it stood when the socket was opened.
  defp authorize(socket) do
    Authz.fetch_initiative(
      socket.assigns.current_user,
      socket.assigns.initiative_id,
      :view,
      require_agent_access: false
    )
  end
end
