defmodule DoIt.TrashTest do
  @moduledoc """
  m02.06 items 10/11 — Initiative-level Trash. Trash → restore → purge
  round-trips, the retention sweep, and the invisibility of a trashed Initiative
  to every member.
  """
  use DoIt.DataCase, async: true

  import Ecto.Query

  alias DoIt.{Accounts, Initiatives}
  alias DoIt.Initiatives.Initiative

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => name,
        "password" => "password123"
      })

    u
  end

  test "trash hides from every member; restore brings it back" do
    owner = user("Owner")
    member = user("Member")
    {:ok, init} = Initiatives.create_initiative(owner, %{"name" => "Shared"})
    {:ok, _} = Initiatives.add_member(init.id, member.id, "editor")

    {:ok, _} = Initiatives.trash_initiative(init)

    # Gone from the owner's AND the member's dashboards.
    refute Enum.any?(Initiatives.list_visible_initiatives(owner), &(&1.id == init.id))
    refute Enum.any?(Initiatives.list_visible_initiatives(member), &(&1.id == init.id))
    # Visible in the owner's Trash only.
    assert Enum.map(Initiatives.list_trashed_initiatives(owner), & &1.id) == [init.id]
    assert Initiatives.list_trashed_initiatives(member) == []

    {:ok, _} = Initiatives.restore_initiative(Initiatives.get_initiative(init.id))

    assert Enum.any?(Initiatives.list_visible_initiatives(owner), &(&1.id == init.id))
    assert Enum.any?(Initiatives.list_visible_initiatives(member), &(&1.id == init.id))
    assert Initiatives.list_trashed_initiatives(owner) == []
  end

  test "purge permanently removes a trashed Initiative" do
    owner = user("Owner")
    {:ok, init} = Initiatives.create_initiative(owner, %{"name" => "Doomed"})
    {:ok, _} = Initiatives.trash_initiative(init)

    {:ok, _} = Initiatives.purge_initiative(Initiatives.get_initiative(init.id))

    assert Initiatives.get_initiative(init.id) == nil
  end

  test "the retention sweep purges only Initiatives trashed past the window" do
    owner = user("Owner")
    {:ok, fresh} = Initiatives.create_initiative(owner, %{"name" => "Fresh"})
    {:ok, stale} = Initiatives.create_initiative(owner, %{"name" => "Stale"})

    {:ok, _} = Initiatives.trash_initiative(fresh)
    {:ok, _} = Initiatives.trash_initiative(stale)

    # Backdate the stale one well past the retention window.
    long_ago =
      DateTime.utc_now()
      |> DateTime.add(-(Initiatives.trash_retention_days() + 5) * 24 * 3600, :second)
      |> DateTime.truncate(:second)

    {1, _} =
      from(i in Initiative, where: i.id == ^stale.id)
      |> DoIt.Repo.update_all(set: [trashed_at: long_ago])

    assert Initiatives.purge_expired_trash() == 1
    assert Initiatives.get_initiative(stale.id) == nil
    assert Initiatives.get_initiative(fresh.id)
  end
end
