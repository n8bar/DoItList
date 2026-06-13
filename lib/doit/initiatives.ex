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
  alias DoIt.Initiatives.{Initiative, InitiativeMember}
  alias DoIt.Tasks.Task

  @doc """
  List initiatives the given user can see, with their role on each loaded
  into the virtual `:my_role` field. Owner-held initiatives sort first; ties
  break by `updated_at` descending.
  """
  def list_visible_initiatives(%User{id: user_id}) do
    from(i in Initiative,
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

  @doc """
  Deletes an initiative. Its tasks, members, and activity cascade away via the
  database FK constraints (ON DELETE CASCADE). Caller must enforce that the
  actor is the owner.
  """
  def delete_initiative(%Initiative{} = initiative) do
    Repo.delete(initiative)
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
  Account deletion (m02.04 §1.10) is blocked while any exist — they need a
  transfer or delete first. m02.06's Trash flow supersedes the block.
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

  def add_member(initiative_id, user_id, role) do
    %InitiativeMember{}
    |> InitiativeMember.changeset(%{initiative_id: initiative_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  def remove_member(initiative_id, user_id) do
    from(m in InitiativeMember,
      where: m.initiative_id == ^initiative_id and m.user_id == ^user_id
    )
    |> Repo.delete_all()
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

          {:ok, _} = update_member_role(initiative.id, new_owner_id, "owner")
          {:ok, _} = update_member_role(initiative.id, old_owner_id, "editor")
          updated
        end)
    end
  end

  def update_member_role(initiative_id, user_id, role) when role in ~w(owner editor viewer) do
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
