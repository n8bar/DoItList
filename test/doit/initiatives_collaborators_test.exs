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

  describe "persistence (item 12.10)" do
    test "a collaborator persists for both people after sharing ends" do
      ann = user("Ann")
      bob = user("Bob")
      {:ok, i1} = Initiatives.create_initiative(ann, %{"name" => "One"})
      {:ok, _} = Initiatives.add_member(i1.id, bob.id, "editor")

      # Stop sharing: remove Bob from the only shared Initiative.
      Initiatives.remove_member(i1.id, bob.id)

      # Bob is still listed for Ann, now a past collaborator (0 shared) …
      assert [%{user: u_b, shared_count: 0}] = Initiatives.list_collaborators(ann)
      assert u_b.id == bob.id
      # … and the record is both-directional, so Bob still keeps Ann too.
      assert [%{user: u_a, shared_count: 0}] = Initiatives.list_collaborators(bob)
      assert u_a.id == ann.id
    end

    test "past collaborators sort below current ones" do
      ann = user("Ann")
      bob = user("Bob")
      cal = user("Cal")
      {:ok, i1} = Initiatives.create_initiative(ann, %{"name" => "One"})
      {:ok, i2} = Initiatives.create_initiative(ann, %{"name" => "Two"})
      {:ok, _} = Initiatives.add_member(i1.id, bob.id, "editor")
      {:ok, _} = Initiatives.add_member(i2.id, cal.id, "viewer")
      # Cal becomes a past collaborator; Bob stays current.
      Initiatives.remove_member(i2.id, cal.id)

      assert [%{user: u1, shared_count: 1}, %{user: u2, shared_count: 0}] =
               Initiatives.list_collaborators(ann)

      assert u1.id == bob.id
      assert u2.id == cal.id
    end
  end

  describe "remove_collaborator/2 (item 12.11)" do
    test "removing a past collaborator drops them from your list only" do
      ann = user("Ann")
      bob = user("Bob")
      {:ok, i1} = Initiatives.create_initiative(ann, %{"name" => "One"})
      {:ok, _} = Initiatives.add_member(i1.id, bob.id, "editor")
      Initiatives.remove_member(i1.id, bob.id)

      assert {:ok, _} = Initiatives.remove_collaborator(ann, bob.id)
      assert Initiatives.list_collaborators(ann) == []
      # The reciprocal row is untouched — it's a personal list.
      assert [%{user: u}] = Initiatives.list_collaborators(bob)
      assert u.id == ann.id
    end

    test "removing a current collaborator is rejected" do
      ann = user("Ann")
      bob = user("Bob")
      {:ok, i1} = Initiatives.create_initiative(ann, %{"name" => "One"})
      {:ok, _} = Initiatives.add_member(i1.id, bob.id, "editor")

      assert {:error, :still_collaborating} = Initiatives.remove_collaborator(ann, bob.id)
      assert [%{user: u}] = Initiatives.list_collaborators(ann)
      assert u.id == bob.id
    end

    test "re-collaborating restores a removed collaborator" do
      ann = user("Ann")
      bob = user("Bob")
      {:ok, i1} = Initiatives.create_initiative(ann, %{"name" => "One"})
      {:ok, _} = Initiatives.add_member(i1.id, bob.id, "editor")
      Initiatives.remove_member(i1.id, bob.id)
      {:ok, _} = Initiatives.remove_collaborator(ann, bob.id)
      assert Initiatives.list_collaborators(ann) == []

      {:ok, i2} = Initiatives.create_initiative(ann, %{"name" => "Two"})
      {:ok, _} = Initiatives.add_member(i2.id, bob.id, "viewer")

      assert [%{user: u, shared_count: 1}] = Initiatives.list_collaborators(ann)
      assert u.id == bob.id
    end
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

  describe "list_visible_initiatives/1 member avatars (m02.09 WL3.5)" do
    test "attaches each Initiative's members, owner first then by name" do
      ann = user("Ann")
      cal = user("Cal")
      bob = user("Bob")
      {:ok, i} = Initiatives.create_initiative(ann, %{"name" => "One"})
      {:ok, _} = Initiatives.add_member(i.id, cal.id, "viewer")
      {:ok, _} = Initiatives.add_member(i.id, bob.id, "editor")

      [visible] = Initiatives.list_visible_initiatives(ann)
      member_ids = Enum.map(visible.members, & &1.id)

      # The owner (Ann) leads; the rest follow by name (Bob, Cal).
      assert member_ids == [ann.id, bob.id, cal.id]
      # Members are full %User{} structs (the avatar component reads them).
      assert Enum.all?(visible.members, &match?(%Accounts.User{}, &1))
    end

    test "a freshly added viewer shows up in the member list (Fix B reconcile)" do
      ann = user("Ann")
      cal = user("Cal")
      {:ok, i} = Initiatives.create_initiative(ann, %{"name" => "One"})

      assert {:ok, _} = Initiatives.add_collaborator_as_viewer(ann, i.id, cal.id)

      [visible] = Initiatives.list_visible_initiatives(ann)
      assert cal.id in Enum.map(visible.members, & &1.id)
    end
  end
end
