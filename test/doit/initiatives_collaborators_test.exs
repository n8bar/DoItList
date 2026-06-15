defmodule DoIt.InitiativesCollaboratorsTest do
  @moduledoc """
  m02.05 item 8 — the cross-Initiative Collaborators query: everyone the user
  shares an Initiative with, deduplicated across Initiatives, counted, and
  ordered most-shared-first. Excludes the user themselves; empty when they
  share nothing.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives}

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

  test "dedupes, counts shared Initiatives, sorts most-shared-first, excludes self" do
    ann = user("Ann")
    bob = user("Bob")
    cal = user("Cal")

    {:ok, i1} = Initiatives.create_initiative(ann, %{"name" => "One"})
    {:ok, i2} = Initiatives.create_initiative(ann, %{"name" => "Two"})

    # Bob shares both i1 and i2 with Ann; Cal shares only i1.
    {:ok, _} = Initiatives.add_member(i1.id, bob.id, "editor")
    {:ok, _} = Initiatives.add_member(i1.id, cal.id, "viewer")
    {:ok, _} = Initiatives.add_member(i2.id, bob.id, "viewer")

    collabs = Initiatives.list_collaborators(ann)

    # Bob (2 shared) ahead of Cal (1 shared); Bob appears once despite 2 shares.
    assert [%{user: u1, shared_count: 2}, %{user: u2, shared_count: 1}] = collabs
    assert u1.id == bob.id
    assert u2.id == cal.id
    refute Enum.any?(collabs, &(&1.user.id == ann.id))
  end

  test "empty when the user shares no Initiative with anyone" do
    loner = user("Lon")
    # A solo Initiative (only member is the owner) yields no collaborators.
    {:ok, _solo} = Initiatives.create_initiative(loner, %{"name" => "Solo"})

    assert Initiatives.list_collaborators(loner) == []
  end

  describe "add_collaborator_as_viewer/3 (items 9–10)" do
    test "owner adds a known user as viewer" do
      ann = user("Ann")
      cal = user("Cal")
      {:ok, i} = Initiatives.create_initiative(ann, %{"name" => "One"})

      assert {:ok, added} = Initiatives.add_collaborator_as_viewer(ann, i.id, cal.id)
      assert added.id == cal.id
      assert Initiatives.get_role(i.id, cal.id) == "viewer"
    end

    test "an existing member is a no-op" do
      ann = user("Ann")
      cal = user("Cal")
      {:ok, i} = Initiatives.create_initiative(ann, %{"name" => "One"})
      {:ok, _} = Initiatives.add_member(i.id, cal.id, "editor")

      assert {:error, :already_member} = Initiatives.add_collaborator_as_viewer(ann, i.id, cal.id)
      # The existing role is untouched (not downgraded to viewer).
      assert Initiatives.get_role(i.id, cal.id) == "editor"
    end

    test "a non-admin actor is forbidden" do
      ann = user("Ann")
      bob = user("Bob")
      dot = user("Dot")
      {:ok, i} = Initiatives.create_initiative(ann, %{"name" => "One"})
      # Bob is only a viewer here — can't administer the roster.
      {:ok, _} = Initiatives.add_member(i.id, bob.id, "viewer")

      assert {:error, :forbidden} = Initiatives.add_collaborator_as_viewer(bob, i.id, dot.id)
      assert Initiatives.get_role(i.id, dot.id) == nil
    end
  end
end
