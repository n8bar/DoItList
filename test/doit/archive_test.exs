defmodule DoIt.ArchiveTest do
  @moduledoc """
  m02.08 worklist 4 — per-user Archive + Hide. Both flags live on the caller's
  OWN membership row, so they move an Initiative out of only that member's active
  list (never anyone else's view). Archive → restorable Archived list; Hide →
  the lighter "off my dashboard" move, unhidden from the same list. Plus the
  item 4.2 confirm-needed check (member vs owner).
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

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

  defp new_task(actor, initiative, attrs) do
    parent_id = Map.get(attrs, "parent_id") || initiative.root_task_id

    {:ok, task} =
      Tasks.create_task(
        actor,
        attrs |> Map.put("initiative_id", initiative.id) |> Map.put("parent_id", parent_id)
      )

    task
  end

  defp visible_ids(user),
    do: Initiatives.list_visible_initiatives(user) |> Enum.map(& &1.id)

  defp archived_ids(user),
    do: Initiatives.list_archived_initiatives(user) |> Enum.map(& &1.id)

  describe "archive / unarchive (per-user)" do
    test "archive drops it from the caller's active list into their Archived list" do
      owner = user("Owner")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})

      assert ini.id in visible_ids(owner)

      {:ok, 1} = Initiatives.archive_initiative(owner, ini)

      refute ini.id in visible_ids(owner)
      assert ini.id in archived_ids(owner)

      [row] = Initiatives.list_archived_initiatives(owner)
      assert row.archived?
      refute row.hidden?
    end

    test "archive sets ONLY the caller's row — another member's view is unaffected" do
      owner = user("Owner")
      member = user("Member")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Shared"})
      {:ok, _} = Initiatives.add_member(ini.id, member.id, "editor")

      {:ok, 1} = Initiatives.archive_initiative(owner, ini)

      # Gone for the owner, still active for the member.
      refute ini.id in visible_ids(owner)
      assert ini.id in visible_ids(member)
      assert Initiatives.list_archived_initiatives(member) == []
    end

    test "unarchive clears the flag and restores it to the active list" do
      owner = user("Owner")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})

      {:ok, 1} = Initiatives.archive_initiative(owner, ini)
      {:ok, 1} = Initiatives.unarchive_initiative(owner, ini)

      assert ini.id in visible_ids(owner)
      assert archived_ids(owner) == []
    end
  end

  describe "hide / unhide (per-user)" do
    test "hide drops it from the active list; the Archived list keeps it flagged hidden" do
      owner = user("Owner")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})

      {:ok, 1} = Initiatives.hide_initiative(owner, ini)

      refute ini.id in visible_ids(owner)
      [row] = Initiatives.list_archived_initiatives(owner)
      assert row.hidden?
      refute row.archived?
    end

    test "hide sets ONLY the caller's row — others still see it" do
      owner = user("Owner")
      member = user("Member")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Shared"})
      {:ok, _} = Initiatives.add_member(ini.id, member.id, "viewer")

      {:ok, 1} = Initiatives.hide_initiative(member, ini)

      refute ini.id in visible_ids(member)
      assert ini.id in visible_ids(owner)
    end

    test "unhide clears the flag and restores it to the active list" do
      owner = user("Owner")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})

      {:ok, 1} = Initiatives.hide_initiative(owner, ini)
      {:ok, 1} = Initiatives.unhide_initiative(owner, ini)

      assert ini.id in visible_ids(owner)
      assert archived_ids(owner) == []
    end
  end

  describe "archive_needs_confirm?/2" do
    test "owner: true when ANY task is incomplete, false when all complete" do
      owner = user("Owner")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})

      task = new_task(owner, ini, %{"title" => "Do it"})

      # An open task → owner is asked to confirm.
      assert Initiatives.archive_needs_confirm?(owner, ini)

      {:ok, _} = Tasks.toggle_complete(task, owner)

      # All complete → no confirm.
      refute Initiatives.archive_needs_confirm?(owner, ini)
    end

    test "owner: empty Initiative (only the system root) needs no confirm" do
      owner = user("Owner")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Empty"})

      refute Initiatives.archive_needs_confirm?(owner, ini)
    end

    test "member: true with their OWN incomplete primary assignment, false otherwise" do
      owner = user("Owner")
      member = user("Member")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Shared"})
      {:ok, _} = Initiatives.add_member(ini.id, member.id, "editor")

      # A task assigned to someone else, plus one assigned to the member.
      _theirs = new_task(owner, ini, %{"title" => "Not mine", "assignee_id" => owner.id})

      # The member has nothing of their own yet → no confirm.
      refute Initiatives.archive_needs_confirm?(member, ini)

      mine = new_task(owner, ini, %{"title" => "Mine", "assignee_id" => member.id})

      # Now they have an incomplete primary assignment → confirm.
      assert Initiatives.archive_needs_confirm?(member, ini)

      {:ok, _} = Tasks.toggle_complete(mine, member)

      # Completed → no confirm again (the other open task isn't theirs).
      refute Initiatives.archive_needs_confirm?(member, ini)
    end

    test "member: true with their own incomplete CO-assignment" do
      owner = user("Owner")
      member = user("Member")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Shared"})
      {:ok, _} = Initiatives.add_member(ini.id, member.id, "editor")

      co_task = new_task(owner, ini, %{"title" => "Help me"})
      {:ok, _} = Tasks.add_co_assignee(co_task, owner, member.id)

      assert Initiatives.archive_needs_confirm?(member, ini)
    end
  end
end
