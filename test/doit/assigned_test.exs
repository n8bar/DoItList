defmodule DoIt.Tasks.AssignedTest do
  @moduledoc """
  The Assigned-to-Me cross-Initiative query (m02.08 worklist 1 item 4):
  primary + co-assignee, current-member scoping, completed and archived/hidden
  reveal toggles, and exclusion of tasks in Initiatives the user has left.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Initiatives.InitiativeMember
  alias DoIt.Tasks.Assigned

  defp user(name) do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp new_task(owner, initiative, attrs) do
    parent_id = Map.get(attrs, "parent_id") || initiative.root_task_id

    {:ok, task} =
      Tasks.create_task(
        owner,
        attrs |> Map.put("initiative_id", initiative.id) |> Map.put("parent_id", parent_id)
      )

    task
  end

  defp titles(rows), do: Enum.map(rows, & &1.title) |> Enum.sort()

  setup do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})
    %{owner: owner, ini: ini}
  end

  describe "primary + co scoping" do
    test "includes primary-assigned and co-assigned tasks, distinguishing them", %{
      owner: owner,
      ini: ini
    } do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")

      _primary = new_task(owner, ini, %{"title" => "Mine", "assignee_id" => me.id})
      co_task = new_task(owner, ini, %{"title" => "Helping"})
      {:ok, _} = Tasks.add_co_assignee(co_task, owner, me.id)

      # A task assigned to someone else must not appear.
      _theirs = new_task(owner, ini, %{"title" => "Theirs", "assignee_id" => owner.id})

      rows = Assigned.list_assigned_to(me)
      assert titles(rows) == ["Helping", "Mine"]

      by_title = Map.new(rows, &{&1.title, &1})
      assert by_title["Mine"].assigned_as == :primary
      assert by_title["Helping"].assigned_as == :co
      assert by_title["Mine"].initiative_name == "Alpha"
    end

    test "excludes tasks in an Initiative the user has left", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")
      _t = new_task(owner, ini, %{"title" => "Mine", "assignee_id" => me.id})

      assert titles(Assigned.list_assigned_to(me)) == ["Mine"]

      # Drop the membership row → the current-member join excludes the task.
      Repo.delete_all(from m in InitiativeMember, where: m.user_id == ^me.id)
      assert Assigned.list_assigned_to(me) == []
    end
  end

  describe "completed reveal" do
    test "hides completed by default, reveals with include_completed", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")

      _open = new_task(owner, ini, %{"title" => "Open", "assignee_id" => me.id})
      done = new_task(owner, ini, %{"title" => "Done", "assignee_id" => me.id})
      {:ok, _} = Tasks.toggle_complete(done, owner)

      assert titles(Assigned.list_assigned_to(me)) == ["Open"]
      assert titles(Assigned.list_assigned_to(me, include_completed: true)) == ["Done", "Open"]
    end
  end

  describe "archived / hidden reveal" do
    test "hides tasks from archived or hidden Initiatives by default; reveals with the flag", %{
      owner: owner,
      ini: ini
    } do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")
      _t = new_task(owner, ini, %{"title" => "InAlpha", "assignee_id" => me.id})

      {:ok, beta} = Initiatives.create_initiative(owner, %{"name" => "Beta"})
      {:ok, _} = Initiatives.add_member(beta.id, me.id, "editor")
      _b = new_task(owner, beta, %{"title" => "InBeta", "assignee_id" => me.id})

      # Archive Alpha for me only; hide Beta for me only.
      stamp(me.id, ini.id, :archived_at)
      stamp(me.id, beta.id, :hidden_at)

      assert Assigned.list_assigned_to(me) == []

      assert titles(Assigned.list_assigned_to(me, include_archived_hidden: true)) ==
               ["InAlpha", "InBeta"]
    end

    test "archiving/hiding is per-member: another member still sees the task", %{
      owner: owner,
      ini: ini
    } do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")
      _t = new_task(owner, ini, %{"title" => "Shared", "assignee_id" => owner.id})

      # I archive Alpha; the owner's view is untouched.
      stamp(me.id, ini.id, :archived_at)

      assert titles(Assigned.list_assigned_to(owner)) == ["Shared"]
    end
  end

  describe "subtree counts" do
    test "child + leaf counts attach for the mode-aware badge", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")

      branch = new_task(owner, ini, %{"title" => "Branch", "assignee_id" => me.id})
      c1 = new_task(owner, ini, %{"title" => "C1", "parent_id" => branch.id})
      _c1a = new_task(owner, ini, %{"title" => "C1a", "parent_id" => c1.id})
      _c1b = new_task(owner, ini, %{"title" => "C1b", "parent_id" => c1.id})
      _c2 = new_task(owner, ini, %{"title" => "C2", "parent_id" => branch.id})

      _leaf = new_task(owner, ini, %{"title" => "Leaf", "assignee_id" => me.id})

      rows = Map.new(Assigned.list_assigned_to(me), &{&1.title, &1})

      assert rows["Branch"].child_count == 2
      assert rows["Branch"].assigned_leaf_count == 3
      assert rows["Leaf"].child_count == 0
      assert rows["Leaf"].assigned_leaf_count == 1
    end
  end

  # Set archived_at / hidden_at on a member's row for an Initiative (the per-user
  # flags the archive/hide UI lands later; here we stamp directly).
  defp stamp(user_id, initiative_id, field) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(m in InitiativeMember,
      where: m.user_id == ^user_id and m.initiative_id == ^initiative_id
    )
    |> Repo.update_all(set: [{field, now}])
  end
end
