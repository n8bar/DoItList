defmodule DoIt.Orchards do
  @moduledoc """
  Orchard and orchard-membership operations.

  An Orchard is the container for a tree of Tasks. Each Orchard has an owner
  and any number of additional members with role `owner`, `editor`, or `viewer`.
  """

  import Ecto.Query, warn: false

  alias DoIt.Repo
  alias DoIt.Accounts.User
  alias DoIt.Orchards.{Orchard, OrchardMember}

  @doc "List orchards the given user can see (any role)."
  def list_visible_orchards(%User{id: user_id}) do
    from(o in Orchard,
      join: m in OrchardMember,
      on: m.orchard_id == o.id and m.user_id == ^user_id,
      order_by: [desc: o.updated_at]
    )
    |> Repo.all()
  end

  def get_orchard!(id), do: Repo.get!(Orchard, id)
  def get_orchard(id), do: Repo.get(Orchard, id)

  @doc "Create an Orchard and make the creator its owner."
  def create_orchard(%User{} = owner, attrs) do
    attrs = Map.put(stringify_keys(attrs), "owner_id", owner.id)

    Repo.transaction(fn ->
      with {:ok, orchard} <- %Orchard{} |> Orchard.changeset(attrs) |> Repo.insert(),
           {:ok, _member} <-
             %OrchardMember{}
             |> OrchardMember.changeset(%{
               orchard_id: orchard.id,
               user_id: owner.id,
               role: "owner"
             })
             |> Repo.insert() do
        orchard
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def change_orchard(%Orchard{} = orchard, attrs \\ %{}) do
    Orchard.changeset(orchard, attrs)
  end

  def list_members(orchard_id) do
    from(m in OrchardMember,
      where: m.orchard_id == ^orchard_id,
      join: u in User,
      on: u.id == m.user_id,
      order_by: u.name,
      preload: [user: u]
    )
    |> Repo.all()
  end

  @doc "Return %{user_id => role} for quick role lookups."
  def membership_map(orchard_id) do
    from(m in OrchardMember, where: m.orchard_id == ^orchard_id, select: {m.user_id, m.role})
    |> Repo.all()
    |> Map.new()
  end

  def get_role(orchard_id, user_id) do
    Repo.one(
      from m in OrchardMember,
        where: m.orchard_id == ^orchard_id and m.user_id == ^user_id,
        select: m.role
    )
  end

  def add_member(orchard_id, user_id, role) do
    %OrchardMember{}
    |> OrchardMember.changeset(%{orchard_id: orchard_id, user_id: user_id, role: role})
    |> Repo.insert()
  end

  def remove_member(orchard_id, user_id) do
    from(m in OrchardMember,
      where: m.orchard_id == ^orchard_id and m.user_id == ^user_id
    )
    |> Repo.delete_all()
  end

  def update_member_role(orchard_id, user_id, role) when role in ~w(owner editor viewer) do
    case Repo.get_by(OrchardMember, orchard_id: orchard_id, user_id: user_id) do
      nil -> {:error, :not_found}
      member -> member |> OrchardMember.changeset(%{role: role}) |> Repo.update()
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
