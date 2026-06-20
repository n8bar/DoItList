defmodule DoIt.Initiatives do
  @moduledoc """
  Initiative and initiative-membership operations.

  An Initiative is the container for a tree of Tasks. Each Initiative has an
  owner and any number of additional members with role `owner`, `editor`, or
  `viewer`.
  """

  import Ecto.Query, warn: false

  alias DoIt.Repo
  alias DoIt.Accounts.User
  alias DoIt.Initiatives.{Initiative, InitiativeMember, Collaborator}
  alias DoIt.Notifications
  alias DoIt.Tasks.Task

  @doc """
  List initiatives the given user can see, with their role on each loaded
  into the virtual `:my_role` field. Owner-held initiatives sort first; ties
  break by `updated_at` descending.
  """
  def list_visible_initiatives(%User{id: user_id}) do
    from(i in Initiative,
      where: is_nil(i.trashed_at),
      join: m in InitiativeMember,
      on: m.initiative_id == i.id and m.user_id == ^user_id,
      left_join: rt in Task,
      on: rt.id == i.root_task_id,
      select: %{
        i
        | my_role: m.role,
          my_sort_order: m.sort_order,
          subtitle: rt.title,
          progress: rt.computed_progress
      },
      order_by: [
        asc: fragment("CASE WHEN ? = 'owner' THEN 0 ELSE 1 END", m.role),
        desc: i.updated_at
      ]
    )
    |> Repo.all()
  end

  @doc """
  Everyone the given user has ever worked with (m02.05 items 8 + 12.10), drawn
  from the persistent `collaborators` table so people stay after a shared
  Initiative ends. Each row is `%{user: %User{}, shared_count: n}` — `n` is the
  **live** count of Initiatives currently in common (0 for a past collaborator).
  Sorted most-shared-first then by name, so past collaborators (0) sink to the
  bottom. The cross-Initiative people pane in the ultrawide left rail.
  """
  def list_collaborators(%User{id: user_id}) do
    shared =
      from(m1 in InitiativeMember,
        join: m2 in InitiativeMember,
        on: m1.initiative_id == m2.initiative_id,
        where: m1.user_id == ^user_id and m2.user_id != ^user_id,
        group_by: m2.user_id,
        select: %{user_id: m2.user_id, count: count(m1.initiative_id, :distinct)}
      )

    from(c in Collaborator,
      where: c.user_id == ^user_id,
      join: u in User,
      on: u.id == c.collaborator_id,
      left_join: s in subquery(shared),
      on: s.user_id == c.collaborator_id,
      select: %{user: u, shared_count: coalesce(s.count, 0)},
      order_by: [desc: coalesce(s.count, 0), asc: u.name]
    )
    |> Repo.all()
  end

  @doc """
  Remove a past collaborator from the actor's list (m02.05 item 12.11). Deletes
  only the actor's own `(actor → collaborator)` row — the reciprocal stays, as
  it's a personal list. Rejected with `{:error, :still_collaborating}` while the
  two still share any Initiative (removal there would be undone on the next
  co-membership). Returns `{:ok, count}` otherwise.
  """
  def remove_collaborator(%User{id: user_id}, collaborator_id) do
    if shared_initiative_count(user_id, collaborator_id) > 0 do
      {:error, :still_collaborating}
    else
      {count, _} =
        from(c in Collaborator,
          where: c.user_id == ^user_id and c.collaborator_id == ^collaborator_id
        )
        |> Repo.delete_all()

      {:ok, count}
    end
  end

  defp shared_initiative_count(user_id, other_id) do
    Repo.aggregate(
      from(m1 in InitiativeMember,
        join: m2 in InitiativeMember,
        on: m1.initiative_id == m2.initiative_id,
        where: m1.user_id == ^user_id and m2.user_id == ^other_id
      ),
      :count
    )
  end

  # Record the persistent collaborator edges (m02.05 item 12.10) for a member
  # who just joined `initiative_id`: both directions between them and every
  # other current member. Idempotent via the unique index, so re-joins and
  # multi-Initiative overlaps never raise.
  defp record_collaborators(initiative_id, new_user_id) do
    others =
      Repo.all(
        from m in InitiativeMember,
          where: m.initiative_id == ^initiative_id and m.user_id != ^new_user_id,
          select: m.user_id
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      Enum.flat_map(others, fn other ->
        [
          %{user_id: new_user_id, collaborator_id: other, inserted_at: now, updated_at: now},
          %{user_id: other, collaborator_id: new_user_id, inserted_at: now, updated_at: now}
        ]
      end)

    if rows != [], do: Repo.insert_all(Collaborator, rows, on_conflict: :nothing)
  end

  def get_initiative!(id), do: Repo.get!(Initiative, id)
  def get_initiative(id), do: Repo.get(Initiative, id)

  @doc """
  Create an Initiative and make the creator its owner. The owner's "My
  Initiative Defaults" (m02.04 §2.2) seed the progress calc and the root
  task's sort — explicit attrs still win.
  """
  def create_initiative(%User{} = owner, attrs) do
    prefs = DoIt.Accounts.get_preferences(owner)

    attrs =
      stringify_keys(attrs)
      |> Map.put("owner_id", owner.id)
      |> maybe_default_progress_calc(prefs)
      |> Map.put_new("auto_promote_co_assignees", prefs.initiative_auto_promote)
      |> Map.put_new("viewer_plus", prefs.initiative_viewer_plus)

    Repo.transaction(fn ->
      with {:ok, initiative} <- %Initiative{} |> Initiative.changeset(attrs) |> Repo.insert(),
           {:ok, _member} <-
             %InitiativeMember{}
             |> InitiativeMember.changeset(%{
               initiative_id: initiative.id,
               user_id: owner.id,
               role: "owner"
             })
             |> Repo.insert(),
           {:ok, root} <- insert_root_task(initiative, owner, prefs),
           {:ok, initiative} <-
             initiative |> Ecto.Changeset.change(root_task_id: root.id) |> Repo.update() do
        initiative
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp maybe_default_progress_calc(attrs, %{initiative_progress_calc: nil}), do: attrs

  defp maybe_default_progress_calc(attrs, %{initiative_progress_calc: calc}),
    do: Map.put_new(attrs, "progress_calc", calc)

  # The Initiative's system-managed root task: parent_id nil, title a single
  # space. Inserted as a struct (not a changeset) on purpose — Ecto's cast trims
  # whitespace-only strings to empty and validate_required would reject " ", but
  # the root title doubles as the (initially empty) subtitle and the column is
  # min-1. No activity event or broadcast for a system row.
  defp insert_root_task(%Initiative{} = initiative, %User{} = owner, prefs) do
    Repo.insert(%Task{
      initiative_id: initiative.id,
      created_by_id: owner.id,
      title: " ",
      status: "open",
      priority: "normal",
      manual_progress: 0,
      computed_progress: 0,
      sort_order: 0,
      sort_mode: prefs.initiative_sort_mode,
      sort_reverse: prefs.initiative_sort_reverse
    })
  end

  def change_initiative(%Initiative{} = initiative, attrs \\ %{}) do
    Initiative.changeset(initiative, attrs)
  end

  @doc "Update an Initiative's editable fields (name, description). Owner stays as-is."
  def update_initiative(%Initiative{} = initiative, attrs) do
    initiative
    |> Initiative.changeset(stringify_keys(attrs))
    |> Repo.update()
  end

  @doc """
  The Initiative's optional subtitle, stored in its root task's title. Blank
  reads as `""`; the underlying column holds a single space.
  """
  def subtitle(%Initiative{} = initiative) do
    case Repo.get(Task, initiative.root_task_id) do
      %Task{title: title} -> if String.trim(title) == "", do: "", else: title
      _ -> ""
    end
  end

  @doc """
  Sets the Initiative's subtitle by writing the root task's title. A blank value
  is stored as a single space (the column is non-null and a struct-level change
  bypasses the task-title min-1 validation). No-op write path — no activity event.
  """
  def update_subtitle(%Initiative{root_task_id: root_id}, subtitle) when is_binary(subtitle) do
    title = if String.trim(subtitle) == "", do: " ", else: subtitle

    case Repo.get(Task, root_id) do
      %Task{} = root -> root |> Ecto.Changeset.change(title: title) |> Repo.update()
      nil -> {:error, :no_root_task}
    end
  end

  # Trash retention (m02.06 item 11): trashed Initiatives purge automatically
  # after this many days; the owner can purge sooner.
  @trash_retention_days 30

  def trash_retention_days, do: @trash_retention_days

  @doc """
  Move an Initiative to Trash (m02.06 item 10) — a soft delete that drops it
  from every member's dashboard until restored or purged. Caller enforces the
  actor is the owner.
  """
  def trash_initiative(%Initiative{} = initiative) do
    initiative
    |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "Restore a trashed Initiative back to every member's dashboard."
  def restore_initiative(%Initiative{} = initiative) do
    initiative
    |> Ecto.Changeset.change(trashed_at: nil)
    |> Repo.update()
  end

  @doc """
  Permanently delete an Initiative. Its tasks, members, and activity cascade
  away via the FK constraints. The final step out of Trash (owner-only) and
  what the retention sweep calls.
  """
  def purge_initiative(%Initiative{} = initiative) do
    Repo.delete(initiative)
  end

  @doc "The owner's trashed Initiatives, newest-trashed first (the Trash surface)."
  def list_trashed_initiatives(%User{id: user_id}) do
    from(i in Initiative,
      where: i.owner_id == ^user_id and not is_nil(i.trashed_at),
      order_by: [desc: i.trashed_at]
    )
    |> Repo.all()
  end

  @doc """
  Purge every Initiative trashed longer than the retention window (item 11).
  Returns the number purged. Safe to call opportunistically or from a job.
  """
  def purge_expired_trash do
    cutoff = DateTime.utc_now() |> DateTime.add(-@trash_retention_days * 24 * 3600, :second)

    {n, _} =
      from(i in Initiative, where: not is_nil(i.trashed_at) and i.trashed_at < ^cutoff)
      |> Repo.delete_all()

    n
  end

  @doc """
  Persist the user's manual Initiatives-index order (m02.04 §2.6) onto their
  membership rows. Position in the list becomes `sort_order`.
  """
  def set_index_order(%User{id: user_id}, ordered_ids) when is_list(ordered_ids) do
    ordered_ids
    |> Enum.map(&parse_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.with_index()
    |> Enum.each(fn {initiative_id, idx} ->
      from(m in InitiativeMember,
        where: m.user_id == ^user_id and m.initiative_id == ^initiative_id
      )
      |> Repo.update_all(set: [sort_order: idx])
    end)

    :ok
  end

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_id(_), do: nil

  @doc """
  Initiatives this user owns (by `owner_id`) that other members belong to.
  On account deletion these are handed off to a successor member (m02.06 item
  10.3) rather than blocking the deletion.
  """
  def owned_shared_initiatives(%User{id: user_id}) do
    from(i in Initiative,
      where: i.owner_id == ^user_id,
      join: m in InitiativeMember,
      on: m.initiative_id == i.id and m.user_id != ^user_id,
      distinct: true,
      order_by: i.name
    )
    |> Repo.all()
  end

  @doc """
  Delete every initiative the user owns that has no other members. Tasks,
  memberships, and activity cascade away via the FK constraints.
  """
  def delete_sole_owned_initiatives(%User{id: user_id}) do
    sole_ids =
      from(i in Initiative,
        where: i.owner_id == ^user_id,
        left_join: m in InitiativeMember,
        on: m.initiative_id == i.id and m.user_id != ^user_id,
        where: is_nil(m.id),
        select: i.id
      )
      |> Repo.all()

    Repo.delete_all(from(i in Initiative, where: i.id in ^sole_ids))
  end

  @doc """
  Hand off every multi-member Initiative `user` owns to its `successor_member/1`
  (m02.06 item 10.3), so deleting the account doesn't strand them. Solo-owned
  Initiatives are left for `delete_sole_owned_initiatives/1`.
  """
  def transfer_owned_shared_initiatives(%User{} = user) do
    user
    |> owned_shared_initiatives()
    |> Enum.each(fn initiative ->
      case successor_member(initiative) do
        nil -> :ok
        successor_id -> transfer_ownership(initiative, successor_id)
      end
    end)
  end

  @doc """
  The member who should inherit ownership when the current owner departs (m02.06
  item 10.3): the highest-ranked surviving member, ranked **editor > viewer+ >
  viewer**, ties broken by who joined the Initiative earliest. viewer+ (a viewer
  who is the primary assignee of a live task here) only outranks a plain viewer
  when the Initiative's `viewer_plus` is on. Returns a user_id, or nil when the
  owner is the only member.
  """
  def successor_member(%Initiative{} = initiative) do
    members =
      from(m in InitiativeMember,
        where: m.initiative_id == ^initiative.id and m.user_id != ^initiative.owner_id,
        select: %{user_id: m.user_id, role: m.role, joined: m.inserted_at}
      )
      |> Repo.all()

    case members do
      [] ->
        nil

      _ ->
        assignees = direct_assignee_ids(initiative)

        members
        |> Enum.min_by(fn m ->
          {-successor_rank(m, assignees), DateTime.to_unix(m.joined), m.user_id}
        end)
        |> Map.fetch!(:user_id)
    end
  end

  # editor > viewer+ > viewer. viewer+ = a viewer who directly leads a task here;
  # it only elevates them when `direct_assignee_ids` is non-empty (viewer_plus on).
  defp successor_rank(%{role: "editor"}, _assignees), do: 3

  defp successor_rank(%{role: "viewer", user_id: uid}, assignees),
    do: if(MapSet.member?(assignees, uid), do: 2, else: 1)

  defp successor_rank(_member, _assignees), do: 1

  defp direct_assignee_ids(%Initiative{viewer_plus: true} = initiative) do
    from(t in Task,
      where:
        t.initiative_id == ^initiative.id and not is_nil(t.assignee_id) and is_nil(t.deleted_at),
      select: t.assignee_id,
      distinct: true
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp direct_assignee_ids(_initiative), do: MapSet.new()

  def list_members(initiative_id) do
    from(m in InitiativeMember,
      where: m.initiative_id == ^initiative_id,
      join: u in User,
      on: u.id == m.user_id,
      order_by: u.name,
      preload: [user: u]
    )
    |> Repo.all()
  end

  @doc "Return %{user_id => role} for quick role lookups."
  def membership_map(initiative_id) do
    from(m in InitiativeMember,
      where: m.initiative_id == ^initiative_id,
      select: {m.user_id, m.role}
    )
    |> Repo.all()
    |> Map.new()
  end

  def get_role(initiative_id, user_id) do
    Repo.one(
      from m in InitiativeMember,
        where: m.initiative_id == ^initiative_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  @doc """
  Add a member. `actor` (a `%User{}` or user id) is who performed the add — when
  given, the new member gets a `member_added` notification (self-adds excluded).
  Defaults to `nil` for system/seed callers that don't attribute an actor.
  """
  def add_member(initiative_id, user_id, role, actor \\ nil) do
    %InitiativeMember{}
    |> InitiativeMember.changeset(%{initiative_id: initiative_id, user_id: user_id, role: role})
    |> Repo.insert()
    |> tap(fn
      {:ok, _} ->
        record_collaborators(initiative_id, user_id)
        broadcast_members_changed(initiative_id)
        notify_membership(actor, user_id, initiative_id, "member_added")

      _ ->
        :ok
    end)
  end

  @doc """
  Add `user_id` to `initiative_id` as a **viewer** on behalf of `actor` — the
  one-gesture default from the Collaborators pane (m02.05 items 9–10: click-add
  and drag-add). Checks the actor can administer the target Initiative, and
  treats an existing member as a no-op. Returns `{:ok, %User{}}` (the added
  user) or `{:error, :forbidden | :already_member | :failed}`.
  """
  def add_collaborator_as_viewer(%User{} = actor, initiative_id, user_id) do
    cond do
      not can_admin?(get_role(initiative_id, actor.id)) ->
        {:error, :forbidden}

      get_role(initiative_id, user_id) != nil ->
        {:error, :already_member}

      true ->
        case add_member(initiative_id, user_id, "viewer", actor) do
          {:ok, _} -> {:ok, Repo.get(User, user_id)}
          {:error, _} -> {:error, :failed}
        end
    end
  end

  @doc """
  Remove a member. `actor` (a `%User{}` or user id) is who performed the removal
  — when given and not the removed user, they get a `member_removed`
  notification. Defaults to `nil` for system callers.
  """
  def remove_member(initiative_id, user_id, actor \\ nil) do
    from(m in InitiativeMember,
      where: m.initiative_id == ^initiative_id and m.user_id == ^user_id
    )
    |> Repo.delete_all()
    |> tap(fn
      {n, _} when n > 0 ->
        broadcast_members_changed(initiative_id)
        notify_membership(actor, user_id, initiative_id, "member_removed")

      _ ->
        :ok
    end)
  end

  # Drop a member_added / member_removed notification on the affected user,
  # excluding self-actions (notify/4 enforces actor == recipient → skip). The
  # actor arg is a %User{} or a user id; a nil actor (system/seed callers) skips
  # quietly. We resolve the actor's display name once for the flyout line.
  defp notify_membership(nil, _user_id, _initiative_id, _kind), do: :ok

  defp notify_membership(actor, user_id, initiative_id, kind) do
    actor_id = actor_id(actor)

    Notifications.notify(actor_id, user_id, kind, %{
      initiative_id: initiative_id,
      actor_name: actor_name(actor)
    })
  end

  defp actor_id(%User{id: id}), do: id
  defp actor_id(id) when is_integer(id), do: id

  defp actor_name(%User{name: name}), do: name
  defp actor_name(id) when is_integer(id), do: (Repo.get(User, id) || %User{}).name

  # Membership changes fan out on the initiative's existing topic so every
  # open LiveView re-checks its own role — a removed member is ejected
  # without waiting for a refresh, and role changes apply live.
  defp broadcast_members_changed(initiative_id) do
    Phoenix.PubSub.broadcast(
      DoIt.PubSub,
      "initiative:#{initiative_id}",
      {:members_changed, initiative_id}
    )
  end

  @doc """
  Transfer ownership — the "transfer first" path that m02.04 §1.10's
  delete-account block points at. The member becomes `owner_id` (+ role
  owner); the previous owner is demoted to editor.
  """
  def transfer_ownership(%Initiative{} = initiative, new_owner_id) do
    old_owner_id = initiative.owner_id

    cond do
      new_owner_id == old_owner_id ->
        {:error, :already_owner}

      is_nil(get_role(initiative.id, new_owner_id)) ->
        {:error, :not_a_member}

      true ->
        Repo.transaction(fn ->
          {:ok, updated} =
            initiative |> Ecto.Changeset.change(owner_id: new_owner_id) |> Repo.update()

          {:ok, _} = do_update_member_role(initiative.id, new_owner_id, "owner")
          {:ok, _} = do_update_member_role(initiative.id, old_owner_id, "editor")
          updated
        end)
        |> tap(fn
          {:ok, _} -> broadcast_members_changed(initiative.id)
          _ -> :ok
        end)
    end
  end

  def update_member_role(initiative_id, user_id, role) when role in ~w(owner editor viewer) do
    do_update_member_role(initiative_id, user_id, role)
    |> tap(fn
      {:ok, _} -> broadcast_members_changed(initiative_id)
      _ -> :ok
    end)
  end

  # No broadcast — for callers inside a transaction (transfer_ownership
  # broadcasts once, after commit).
  defp do_update_member_role(initiative_id, user_id, role) do
    case Repo.get_by(InitiativeMember, initiative_id: initiative_id, user_id: user_id) do
      nil -> {:error, :not_found}
      member -> member |> InitiativeMember.changeset(%{role: role}) |> Repo.update()
    end
  end

  def can_view?(role) when role in ~w(owner editor viewer), do: true
  def can_view?(_), do: false

  def can_edit?(role) when role in ~w(owner editor), do: true
  def can_edit?(_), do: false

  def can_admin?("owner"), do: true
  def can_admin?(_), do: false

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
