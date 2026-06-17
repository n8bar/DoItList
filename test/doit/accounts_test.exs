defmodule DoIt.AccountsTest do
  use DoIt.DataCase, async: true

  alias DoIt.Accounts
  alias DoIt.Accounts.User

  defp register!(attrs \\ %{}) do
    defaults = %{
      "email" => "user-#{System.unique_integer([:positive])}@example.com",
      "username" => "user-#{System.unique_integer([:positive])}",
      "name" => "Some User",
      "password" => "password123"
    }

    {:ok, user} = Accounts.register_user(Map.merge(defaults, attrs))
    user
  end

  # Force a membership's join time so the "oldest member" tiebreak is unambiguous
  # (timestamps are second-resolution, so same-test adds would otherwise tie).
  defp backdate_membership(initiative_id, user_id, dt) do
    DoIt.Repo.update_all(
      from(m in DoIt.Initiatives.InitiativeMember,
        where: m.initiative_id == ^initiative_id and m.user_id == ^user_id
      ),
      set: [inserted_at: dt]
    )
  end

  describe "registration (§1.4)" do
    test "requires a username" do
      {:error, changeset} =
        Accounts.register_user(%{
          "email" => "nouser@example.com",
          "name" => "No User",
          "password" => "password123"
        })

      assert "can't be blank" in errors_on(changeset).username
    end

    test "normalizes the username on the way in" do
      user = register!(%{"username" => "MiXeD_Case"})
      assert user.username == "mixed_case"
    end
  end

  describe "login by username or email (§1.5)" do
    test "authenticates by email or username, case-insensitively" do
      user =
        register!(%{
          "username" => "loginuser",
          "email" => "login-target@example.com",
          "password" => "password123"
        })

      assert {:ok, %User{id: id}} = Accounts.authenticate("login-target@example.com", "password123")
      assert id == user.id

      assert {:ok, %User{id: ^id}} = Accounts.authenticate("LoginUser", "password123")
      assert {:ok, %User{id: ^id}} = Accounts.authenticate("  loginuser  ", "password123")

      assert {:error, :invalid_credentials} = Accounts.authenticate("loginuser", "wrong-pass")
      assert {:error, :invalid_credentials} = Accounts.authenticate("nobody", "password123")
    end
  end

  describe "change password (§1.7)" do
    test "requires the correct current password" do
      user = register!(%{"password" => "old-password"})

      assert {:error, changeset} =
               Accounts.update_password(user, %{
                 "current_password" => "not-the-one",
                 "password" => "new-password-9",
                 "password_confirmation" => "new-password-9"
               })

      assert "is not your current password" in errors_on(changeset).current_password
      assert {:ok, _} = Accounts.authenticate(user.email, "old-password")
    end

    test "requires the confirmation to match" do
      user = register!(%{"password" => "old-password"})

      assert {:error, changeset} =
               Accounts.update_password(user, %{
                 "current_password" => "old-password",
                 "password" => "new-password-9",
                 "password_confirmation" => "something-else"
               })

      assert "does not match new password" in errors_on(changeset).password_confirmation
    end

    test "changes the password" do
      user = register!(%{"password" => "old-password"})

      assert {:ok, _user} =
               Accounts.update_password(user, %{
                 "current_password" => "old-password",
                 "password" => "new-password-9",
                 "password_confirmation" => "new-password-9"
               })

      assert {:ok, _} = Accounts.authenticate(user.email, "new-password-9")
      assert {:error, :invalid_credentials} = Accounts.authenticate(user.email, "old-password")
    end
  end

  describe "delete account (§1.10)" do
    alias DoIt.Initiatives

    test "deletes the account along with sole-member owned initiatives" do
      user = register!()
      {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Mine alone"})

      assert :ok = Accounts.delete_account(user)
      assert Accounts.get_user(user.id) == nil
      assert Initiatives.get_initiative(initiative.id) == nil
    end

    test "transfers owned multi-member initiatives to the highest-ranked member, then deletes (10.3)" do
      owner = register!()
      viewer = register!()
      editor = register!()
      {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Shared work"})
      {:ok, _} = Initiatives.add_member(initiative.id, viewer.id, "viewer")
      {:ok, _} = Initiatives.add_member(initiative.id, editor.id, "editor")

      assert :ok = Accounts.delete_account(owner)
      assert Accounts.get_user(owner.id) == nil
      # The initiative survives, now owned by the editor (outranks the viewer).
      reloaded = Initiatives.get_initiative(initiative.id)
      assert reloaded.owner_id == editor.id
      assert Initiatives.get_role(initiative.id, editor.id) == "owner"
    end

    test "viewer+ inherits over a plain viewer when no editor remains (10.3)" do
      owner = register!()
      plain = register!()
      lead = register!()
      {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Led"})
      {:ok, _} = Initiatives.add_member(initiative.id, plain.id, "viewer")
      {:ok, _} = Initiatives.add_member(initiative.id, lead.id, "viewer")
      # `lead` is a viewer+ — the direct assignee of a task (viewer_plus on by default).
      {:ok, task} =
        DoIt.Tasks.create_task(owner, %{
          "initiative_id" => initiative.id,
          "parent_id" => initiative.root_task_id,
          "title" => "Task"
        })

      {:ok, _} = DoIt.Tasks.update_task(task, owner, %{"assignee_id" => to_string(lead.id)})

      assert :ok = Accounts.delete_account(owner)
      assert Initiatives.get_initiative(initiative.id).owner_id == lead.id
    end

    test "within the same rank, the earliest-joined member inherits (10.3)" do
      owner = register!()
      newer = register!()
      older = register!()
      {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Tie"})
      {:ok, _} = Initiatives.add_member(initiative.id, older.id, "editor")
      {:ok, _} = Initiatives.add_member(initiative.id, newer.id, "editor")
      backdate_membership(initiative.id, older.id, ~U[2020-01-01 00:00:00Z])

      assert :ok = Accounts.delete_account(owner)
      assert Initiatives.get_initiative(initiative.id).owner_id == older.id
    end

    test "viewer+ rank is ignored when the initiative's viewer_plus is off (10.3)" do
      owner = register!()
      older_plain = register!()
      newer_lead = register!()

      {:ok, initiative} =
        Initiatives.create_initiative(owner, %{"name" => "No VP", "viewer_plus" => false})

      {:ok, _} = Initiatives.add_member(initiative.id, older_plain.id, "viewer")
      {:ok, _} = Initiatives.add_member(initiative.id, newer_lead.id, "viewer")
      backdate_membership(initiative.id, older_plain.id, ~U[2020-01-01 00:00:00Z])
      # newer_lead is a direct assignee, but viewer_plus is off so it doesn't elevate them.
      {:ok, task} =
        DoIt.Tasks.create_task(owner, %{
          "initiative_id" => initiative.id,
          "parent_id" => initiative.root_task_id,
          "title" => "Task"
        })

      {:ok, _} = DoIt.Tasks.update_task(task, owner, %{"assignee_id" => to_string(newer_lead.id)})

      assert :ok = Accounts.delete_account(owner)
      # Both rank as plain viewers → oldest wins.
      assert Initiatives.get_initiative(initiative.id).owner_id == older_plain.id
    end

    test "membership in someone else's initiative doesn't block deletion" do
      owner = register!()
      member = register!()
      {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Not yours"})
      {:ok, _} = Initiatives.add_member(initiative.id, member.id, "editor")

      assert :ok = Accounts.delete_account(member)
      assert Initiatives.get_initiative(initiative.id)
      refute Enum.any?(Initiatives.list_members(initiative.id), &(&1.user_id == member.id))
    end
  end

  describe "preferences (§2)" do
    alias DoIt.Initiatives, as: Inits

    test "defaults exist without a row; saving creates one and round-trips" do
      user = register!()
      prefs = Accounts.get_preferences(user)
      assert prefs.id == nil
      assert prefs.task_priority == "normal"
      assert prefs.show_task_activity

      {:ok, saved} = Accounts.update_preferences(user, %{"initiative_progress_calc" => "single_level"})
      assert saved.id
      assert Accounts.get_preferences(user).initiative_progress_calc == "single_level"

      {:error, changeset} = Accounts.update_preferences(user, %{"task_priority" => "bogus"})
      refute changeset.valid?
    end

    test "My Initiative Defaults seed new initiatives (§2.2)" do
      user = register!()

      {:ok, _} =
        Accounts.update_preferences(user, %{
          "initiative_sort_mode" => "alphabetical",
          "initiative_sort_reverse" => "true",
          "initiative_progress_calc" => "single_level"
        })

      {:ok, initiative} = Inits.create_initiative(user, %{"name" => "Prefab"})
      root = DoIt.Repo.get!(DoIt.Tasks.Task, initiative.root_task_id)

      assert initiative.progress_calc == "single_level"
      assert root.sort_mode == "alphabetical"
      assert root.sort_reverse == true
    end

    test "no preferences row means today's defaults (§2.2)" do
      user = register!()
      {:ok, initiative} = Inits.create_initiative(user, %{"name" => "Plain"})
      root = DoIt.Repo.get!(DoIt.Tasks.Task, initiative.root_task_id)

      assert initiative.progress_calc == "leaf_average"
      assert root.sort_mode == nil
      assert root.sort_reverse == false
    end

    test "My Task Defaults apply by initiative owner, with match-parent priority (§2.3)" do
      alias DoIt.Tasks

      owner = register!()
      member = register!()

      {:ok, _} =
        Accounts.update_preferences(owner, %{
          "task_sort_mode" => "alphabetical",
          "task_priority" => "match_parent",
          "task_assign_owner" => "true"
        })

      {:ok, initiative} = Inits.create_initiative(owner, %{"name" => "Owned"})
      {:ok, _} = Inits.add_member(initiative.id, member.id, "editor")

      # Root-level task (parent = system root): match-parent priority falls
      # back to normal; owner defaults apply even though the member creates it.
      {:ok, top} =
        Tasks.create_task(member, %{
          "initiative_id" => initiative.id,
          "parent_id" => initiative.root_task_id,
          "title" => "Top"
        })

      assert top.sort_mode == "alphabetical"
      assert top.priority == "normal"
      assert top.assignee_id == owner.id

      # Under a high-priority parent, match-parent copies "high".
      {:ok, _} = Tasks.update_task(top, owner, %{"priority" => "high"})

      {:ok, child} =
        Tasks.create_task(owner, %{
          "initiative_id" => initiative.id,
          "parent_id" => top.id,
          "title" => "Child"
        })

      assert child.priority == "high"

      # Explicit attrs still win over the defaults.
      {:ok, explicit} =
        Tasks.create_task(owner, %{
          "initiative_id" => initiative.id,
          "parent_id" => initiative.root_task_id,
          "title" => "Explicit",
          "priority" => "low",
          "assignee_id" => member.id
        })

      assert explicit.priority == "low"
      assert explicit.assignee_id == member.id
    end
  end

  describe "username rules (m02.04 §1.2)" do
    test "accepts the allowed charset, trims and downcases" do
      user = register!()

      changeset = User.username_changeset(user, %{"username" => "  Nate_B-99  "})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :username) == "nate_b-99"
    end

    test "rejects bad charsets, bad leading chars, and bad lengths" do
      user = register!()

      for bad <- ["with space", "dots.are.out", "ab", "-leading-dash", "_leading_underscore", String.duplicate("a", 31)] do
        changeset = User.username_changeset(user, %{"username" => bad})
        refute changeset.valid?, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "is required" do
      changeset = User.username_changeset(register!(), %{"username" => ""})
      refute changeset.valid?
    end

    test "enforces uniqueness case-insensitively" do
      taken = register!()
      {:ok, taken} = taken |> User.username_changeset(%{"username" => "shared"}) |> Repo.update()

      other = register!()
      changeset = User.username_changeset(other, %{"username" => "SHARED"})

      refute changeset.valid?
      assert {"has already been taken", _} = changeset.errors[:username]
      assert taken.username == "shared"
    end
  end
end
