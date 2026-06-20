defmodule DoIt.Notifications do
  @moduledoc """
  Per-user, cross-Initiative unread feed (m02.08 worklist 2) — the unread
  subset of "what happened to me", distinct from the per-task Activity log.

  Generation, queries, and the read/unread lifecycle all live here (pure and
  tested); the flyout + nav dot only read from it. Each create broadcasts on
  the recipient's per-user topic (`user_topic/1`) so any authenticated LiveView
  can push the dot live (subscribe + `attach_hook` in `DoItWeb.UserAuth`).

  `kind` is a fixed internal vocabulary (never `String.to_atom` on user input):

    * `member_added`   — added to an Initiative as a member
    * `member_removed` — removed from an Initiative
    * `role_changed`   — your role on an Initiative was changed by an admin
    * `assigned`       — made the primary assignee of a task
    * `unassigned`     — cleared as the primary assignee of a task
    * `co_assigned`    — added as a co-assignee on a task
    * `co_unassigned`  — removed as a co-assignee on a task

  `data` carries the subject ids the flyout links to: `initiative_id` always,
  plus `task_id` for the task-scoped kinds, `role` for `role_changed`, and
  `actor_name` for display.
  """

  import Ecto.Query, warn: false

  alias DoIt.Repo
  alias DoIt.Accounts.User
  alias DoIt.Notifications.Notification

  @kinds ~w(member_added member_removed role_changed assigned unassigned co_assigned co_unassigned)

  @recent_limit 10

  @doc "The PubSub topic carrying a user's notifications."
  def user_topic(user_id), do: "notifications:#{user_id}"

  @doc "The fixed `kind` vocabulary."
  def kinds, do: @kinds

  @doc """
  Create a notification for `recipient_id` and broadcast it on their per-user
  topic. `data` should carry the subject ids the flyout links to. Returns
  `{:ok, notification}` or an Ecto error tuple.

  Never call this when the recipient is the actor — self-exclusion is enforced
  one level up at each generation point (the actor id is always in hand there),
  so the context stays a thin, reusable create.
  """
  def create(recipient_id, kind, data \\ %{}) when kind in @kinds do
    result =
      %Notification{}
      |> Notification.changeset(%{user_id: recipient_id, kind: kind, data: stringify(data)})
      |> Repo.insert()

    case result do
      {:ok, notification} ->
        Phoenix.PubSub.broadcast(
          DoIt.PubSub,
          user_topic(recipient_id),
          {:notification, notification}
        )

        {:ok, notification}

      other ->
        other
    end
  end

  @doc """
  Generate a notification for `recipient_id` unless they are the actor.
  Self-exclusion is a hard rule (actor == recipient → create nothing); this is
  the one entry point every generation site uses. Returns `:skip` when skipped.
  """
  def notify(actor_id, recipient_id, kind, data \\ %{})

  def notify(actor_id, actor_id, _kind, _data), do: :skip
  def notify(_actor_id, nil, _kind, _data), do: :skip

  def notify(_actor_id, recipient_id, kind, data) when kind in @kinds do
    create(recipient_id, kind, data)
  end

  @doc "Most-recent notifications for a user, newest-first (capped for the flyout)."
  def list_recent(%User{id: user_id}, limit \\ @recent_limit) do
    from(n in Notification,
      where: n.user_id == ^user_id,
      order_by: [desc: n.inserted_at, desc: n.id],
      limit: ^limit
    )
    |> Repo.all()
  end

  @doc "Count of the user's unread notifications (`read_at` IS NULL)."
  def unread_count(%User{id: user_id}) do
    Repo.aggregate(
      from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at)),
      :count
    )
  end

  @doc "Mark a single notification read (no-op if already read)."
  def mark_read(%Notification{} = notification) do
    notification
    |> Notification.changeset(%{read_at: now()})
    |> Repo.update()
  end

  @doc """
  Mark every unread notification for the user read. Returns the number marked.
  This is what opening the flyout fires, and the "mark all read" affordance.
  """
  def mark_all_read(%User{id: user_id}) do
    {n, _} =
      from(n in Notification, where: n.user_id == ^user_id and is_nil(n.read_at))
      |> Repo.update_all(set: [read_at: now()])

    n
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # `data` keys are an internal vocabulary, but stringify so the map round-trips
  # identically through the :map (jsonb) column on read.
  defp stringify(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
