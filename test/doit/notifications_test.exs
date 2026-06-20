defmodule DoIt.NotificationsTest do
  @moduledoc """
  Notifications context + auto-generation (m02.08 worklist 2): a per-event-type
  notification is dropped on the recipient (never the actor), the unread count
  and recent feed read back, and reads clear individually and in bulk.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Notifications, Repo, Tasks}
  alias DoIt.Notifications.Notification

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

  defp new_task(owner, ini, attrs) do
    {:ok, t} =
      Tasks.create_task(
        owner,
        attrs
        |> Map.put("initiative_id", ini.id)
        |> Map.put_new("parent_id", ini.root_task_id)
      )

    t
  end

  defp kinds_for(%{id: user_id}) do
    from(n in Notification, where: n.user_id == ^user_id, select: n.kind)
    |> Repo.all()
  end

  setup do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})
    %{owner: owner, ini: ini}
  end

  describe "context: create / read lifecycle" do
    test "unread_count counts only unread; mark_read clears one", %{owner: owner} do
      {:ok, n1} = Notifications.create(owner.id, "member_added", %{initiative_id: 1})
      {:ok, _n2} = Notifications.create(owner.id, "member_added", %{initiative_id: 2})

      assert Notifications.unread_count(owner) == 2

      {:ok, _} = Notifications.mark_read(n1)
      assert Notifications.unread_count(owner) == 1
    end

    test "mark_all_read clears every unread for the user", %{owner: owner} do
      other = user("other")
      {:ok, _} = Notifications.create(owner.id, "assigned", %{initiative_id: 1, task_id: 1})
      {:ok, _} = Notifications.create(owner.id, "assigned", %{initiative_id: 1, task_id: 2})
      {:ok, _} = Notifications.create(other.id, "assigned", %{initiative_id: 1, task_id: 3})

      assert Notifications.mark_all_read(owner) == 2
      assert Notifications.unread_count(owner) == 0
      # Another user's unread is untouched.
      assert Notifications.unread_count(other) == 1
    end

    test "list_recent is newest-first and capped", %{owner: owner} do
      for i <- 1..15 do
        {:ok, _} = Notifications.create(owner.id, "member_added", %{initiative_id: i})
      end

      recent = Notifications.list_recent(owner)
      assert length(recent) == 10
      # Newest (highest id, inserted last) leads.
      assert hd(recent).data["initiative_id"] == 15
    end

    test "data round-trips with string keys", %{owner: owner} do
      {:ok, n} =
        Notifications.create(owner.id, "co_assigned", %{initiative_id: 7, task_id: 9})

      reloaded = Repo.get!(Notification, n.id)
      assert reloaded.data == %{"initiative_id" => 7, "task_id" => 9}
    end
  end

  describe "notify/4 self-exclusion" do
    test "actor == recipient creates nothing", %{owner: owner} do
      assert Notifications.notify(owner.id, owner.id, "assigned", %{initiative_id: 1}) == :skip
      assert kinds_for(owner) == []
    end

    test "nil recipient creates nothing", %{owner: owner} do
      assert Notifications.notify(owner.id, nil, "assigned", %{}) == :skip
    end

    test "a different recipient gets the notification", %{owner: owner} do
      other = user("other")
      assert {:ok, _} = Notifications.notify(owner.id, other.id, "assigned", %{initiative_id: 1})
      assert kinds_for(other) == ["assigned"]
    end
  end

  describe "generation: membership" do
    test "member_added when someone else adds you", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)
      assert kinds_for(me) == ["member_added"]
      # The actor (owner) is not notified about their own add.
      assert kinds_for(owner) == []
    end

    test "member_removed when someone else removes you", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)
      {_n, _} = Initiatives.remove_member(ini.id, me.id, owner)

      assert "member_removed" in kinds_for(me)
    end

    test "leaving on your own (actor == removed) creates nothing", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)
      # Self-removal: actor is the leaving member.
      {_n, _} = Initiatives.remove_member(ini.id, me.id, me)

      refute "member_removed" in kinds_for(me)
    end

    test "system add (no actor) creates nothing", %{ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")
      assert kinds_for(me) == []
    end
  end

  describe "generation: role change" do
    test "role_changed when an admin changes your role", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)

      {:ok, _} = Initiatives.update_member_role(ini.id, me.id, "viewer", owner)

      assert "role_changed" in kinds_for(me)
      # The actor (owner) is not notified about a role change they made.
      assert kinds_for(owner) == []
    end

    test "role_changed carries the new role for the flyout", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)

      {:ok, _} = Initiatives.update_member_role(ini.id, me.id, "viewer", owner)

      [n] =
        from(n in Notification, where: n.user_id == ^me.id and n.kind == "role_changed")
        |> Repo.all()

      assert n.data["role"] == "viewer"
      assert n.data["initiative_id"] == ini.id
    end

    test "changing your own role creates nothing (self-exclusion)", %{owner: owner, ini: ini} do
      # Owner acting on themselves: actor == recipient → notify/4 skips.
      {:ok, _} = Initiatives.update_member_role(ini.id, owner.id, "editor", owner)
      refute "role_changed" in kinds_for(owner)
    end

    test "system role change (no actor) creates nothing", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)

      {:ok, _} = Initiatives.update_member_role(ini.id, me.id, "viewer")

      refute "role_changed" in kinds_for(me)
    end

    test "transfer_ownership does NOT emit role_changed", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)

      {:ok, _} = Initiatives.transfer_ownership(ini, me.id)

      # The private do_update_member_role path the transfer uses must stay
      # silent: neither the new owner nor the demoted old owner is notified.
      refute "role_changed" in kinds_for(me)
      refute "role_changed" in kinds_for(owner)
    end
  end

  describe "generation: primary assignee" do
    test "assigned when set on you by someone else", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)
      task = new_task(owner, ini, %{"title" => "T"})

      {:ok, _} = Tasks.update_task(task, owner, %{"assignee_id" => me.id})
      assert "assigned" in kinds_for(me)
    end

    test "unassigned when cleared on you", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)
      task = new_task(owner, ini, %{"title" => "T", "assignee_id" => me.id})

      reloaded = Tasks.get_task!(task.id)
      {:ok, _} = Tasks.update_task(reloaded, owner, %{"assignee_id" => nil})

      assert "unassigned" in kinds_for(me)
    end

    test "self-assign creates nothing", %{owner: owner, ini: ini} do
      task = new_task(owner, ini, %{"title" => "T"})
      {:ok, _} = Tasks.update_task(task, owner, %{"assignee_id" => owner.id})
      assert kinds_for(owner) == []
    end
  end

  describe "generation: co-assignee" do
    test "co_assigned when added as a co by someone else", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)
      task = new_task(owner, ini, %{"title" => "T"})

      {:ok, _} = Tasks.add_co_assignee(task, owner, me.id)
      assert "co_assigned" in kinds_for(me)
    end

    test "co_unassigned when removed as a co", %{owner: owner, ini: ini} do
      me = user("me")
      {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor", owner)
      task = new_task(owner, ini, %{"title" => "T"})
      {:ok, _} = Tasks.add_co_assignee(task, owner, me.id)

      {:ok, _} = Tasks.remove_co_assignee(task, owner, me.id)
      assert "co_unassigned" in kinds_for(me)
    end

    test "adding yourself as co creates nothing", %{owner: owner, ini: ini} do
      task = new_task(owner, ini, %{"title" => "T"})
      {:ok, _} = Tasks.add_co_assignee(task, owner, owner.id)
      assert kinds_for(owner) == []
    end
  end

  describe "live push" do
    test "create broadcasts on the recipient's per-user topic", %{owner: owner} do
      Phoenix.PubSub.subscribe(DoIt.PubSub, Notifications.user_topic(owner.id))

      {:ok, notification} =
        Notifications.create(owner.id, "member_added", %{initiative_id: 1})

      assert_receive {:notification, ^notification}
    end
  end
end
