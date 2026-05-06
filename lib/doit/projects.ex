defmodule DoIt.Projects do
  @moduledoc """
  Project and project-membership operations.

  A Project is the container for a tree of Tasks. Each project has an owner
  and any number of additional members with role `owner`, `editor`, or `viewer`.
  """

  import Ecto.Query, warn: false

  alias DoIt.Repo
  alias DoIt.Accounts.User
  alias DoIt.Projects.{Project, ProjectMember}

  @doc "List projects the given user can see (any role)."
  def list_visible_projects(%User{id: user_id}) do
    from(p in Project,
      join: m in ProjectMember,
      on: m.project_id == p.id and m.user_id == ^user_id,
      order_by: [desc: p.updated_at]
    )
    |> Repo.all()
  end

  def get_project!(id), do: Repo.get!(Project, id)
  def get_project(id), do: Repo.get(Project, id)

  @doc "Create a project and make the creator its owner."
  def create_project(%User{} = owner, attrs) do
    attrs = Map.put(stringify_keys(attrs), "owner_id", owner.id)

    Repo.transaction(fn ->
      with {:ok, project} <- %Project{} |> Project.changeset(attrs) |> Repo.insert(),
           {:ok, _member} <-
             %ProjectMember{}
             |> ProjectMember.changeset(%{
               project_id: project.id,
               user_id: owner.id,
               role: "owner"
             })
             |> Repo.insert() do
        project
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end

  def list_members(project_id) do
    from(m in ProjectMember,
      where: m.project_id == ^project_id,
      join: u in User,
      on: u.id == m.user_id,
      order_by: u.name,
      preload: [user: u]
    )
    |> Repo.all()
  end

  @doc "Return %{user_id => role} for quick role lookups."
  def membership_map(project_id) do
    from(m in ProjectMember, where: m.project_id == ^project_id, select: {m.user_id, m.role})
    |> Repo.all()
    |> Map.new()
  end

  def get_role(project_id, user_id) do
    Repo.one(
      from m in ProjectMember,
        where: m.project_id == ^project_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  def add_member(project_id, user_id, role) do
    %ProjectMember{}
    |> ProjectMember.changeset(%{project_id: project_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  def remove_member(project_id, user_id) do
    from(m in ProjectMember,
      where: m.project_id == ^project_id and m.user_id == ^user_id
    )
    |> Repo.delete_all()
  end

  def update_member_role(project_id, user_id, role) when role in ~w(owner editor viewer) do
    case Repo.get_by(ProjectMember, project_id: project_id, user_id: user_id) do
      nil -> {:error, :not_found}
      member -> member |> ProjectMember.changeset(%{role: role}) |> Repo.update()
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
