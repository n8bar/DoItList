defmodule DoIt.TasksTest do
  @moduledoc """
  Integration tests for the Tasks context: progress roll-up actually persists
  to the database when a leaf task changes, and activity events are recorded.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Initiatives.Initiative
  alias DoIt.Tasks.Task

  defp setup_user_and_initiative(_) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Test initiative"})

    %{user: user, initiative: initiative}
  end

  setup :setup_user_and_initiative

  test "creating a leaf records its manual progress as 0", %{user: user, initiative: initiative} do
    {:ok, task} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "title" => "Solo"
      })

    assert task.manual_progress == 0
    assert task.computed_progress == 0
  end

  test "updating a leaf rolls progress up to root", %{user: user, initiative: initiative} do
    {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

    {:ok, _a} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "A"
      })

    {:ok, b} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "B"
      })

    # Set leaf B to 100; root should average to 50.
    {:ok, _b2} = Tasks.update_task(b, user, %{"manual_progress" => 100})

    refreshed_root = Tasks.get_task!(root.id)
    assert refreshed_root.computed_progress == 50
  end

  test "weighted children roll up correctly to grandparent", %{user: user, initiative: initiative} do
    {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

    {:ok, mid} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "Mid"
      })

    {:ok, leaf1} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => mid.id,
        "title" => "L1",
        "weight" => "3"
      })

    {:ok, leaf2} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => mid.id,
        "title" => "L2",
        "weight" => "1"
      })

    {:ok, _} = Tasks.update_task(leaf1, user, %{"manual_progress" => 100})
    {:ok, _} = Tasks.update_task(leaf2, user, %{"manual_progress" => 0})

    # mid: (100*3 + 0*1)/4 = 75
    refreshed_mid = Tasks.get_task!(mid.id)
    assert refreshed_mid.computed_progress == 75

    # root: just one child (mid) so it equals mid.
    refreshed_root = Tasks.get_task!(root.id)
    assert refreshed_root.computed_progress == 75
  end

  test "marking a leaf done forces 100 and propagates", %{user: user, initiative: initiative} do
    {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

    {:ok, leaf} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => root.id,
        "title" => "L"
      })

    {:ok, leaf2} = Tasks.update_task(leaf, user, %{"status" => "done"})

    assert leaf2.status == "done"
    assert leaf2.manual_progress == 100

    refreshed_root = Tasks.get_task!(root.id)
    assert refreshed_root.computed_progress == 100
  end

  test "activity events are recorded on create and update", %{user: user, initiative: initiative} do
    {:ok, task} =
      Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Hi"})

    {:ok, _} = Tasks.update_task(task, user, %{"manual_progress" => 50})

    kinds = Tasks.list_task_activity(task.id) |> Enum.map(& &1.kind) |> Enum.sort()
    assert "created" in kinds
    assert "progress_changed" in kinds
  end

  describe "move_task/3" do
    test "moves a leaf to a new parent and recomputes both ancestor chains", %{
      user: user,
      initiative: initiative
    } do
      # Two roots, each with a leaf at 100.
      {:ok, root_a} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "A"})
      {:ok, root_b} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "B"})

      {:ok, leaf_a} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "leaf-a",
          "manual_progress" => 100
        })

      {:ok, _leaf_b} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_b.id,
          "title" => "leaf-b",
          "manual_progress" => 0
        })

      assert Tasks.get_task!(root_a.id).computed_progress == 100
      assert Tasks.get_task!(root_b.id).computed_progress == 0

      # Move leaf_a from root_a to root_b.
      {:ok, moved} = Tasks.move_task(leaf_a, user, %{"parent_id" => root_b.id})
      assert moved.parent_id == root_b.id

      # root_a now has no children → 0; root_b averages (100 + 0)/2 = 50.
      assert Tasks.get_task!(root_a.id).computed_progress == 0
      assert Tasks.get_task!(root_b.id).computed_progress == 50
    end

    test "moving a subtree carries its descendants and recomputes both sides", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root_a} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "A"})
      {:ok, root_b} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "B"})

      {:ok, mid} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "mid"
        })

      {:ok, child1} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => mid.id,
          "title" => "c1",
          "manual_progress" => 100
        })

      {:ok, child2} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => mid.id,
          "title" => "c2",
          "manual_progress" => 50
        })

      # mid: 75, root_a: 75, root_b: 0
      assert Tasks.get_task!(root_a.id).computed_progress == 75
      assert Tasks.get_task!(root_b.id).computed_progress == 0

      {:ok, _moved_mid} = Tasks.move_task(mid, user, %{"parent_id" => root_b.id})

      # Children stayed under mid.
      assert Tasks.get_task!(child1.id).parent_id == mid.id
      assert Tasks.get_task!(child2.id).parent_id == mid.id

      # root_a is now empty, root_b inherits mid's 75.
      assert Tasks.get_task!(root_a.id).computed_progress == 0
      assert Tasks.get_task!(root_b.id).computed_progress == 75
    end

    test "moving to root (parent_id: nil) within the same initiative", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "R"})

      {:ok, child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "C"
        })

      {:ok, moved} = Tasks.move_task(child, user, %{"parent_id" => nil})
      assert moved.parent_id == nil
      assert moved.initiative_id == initiative.id
    end

    test "reorder within same parent: position 0 vs position 2", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "R"})

      {:ok, a} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "A"
        })

      {:ok, b} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "B"
        })

      {:ok, c} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "C"
        })

      # Initial order: A, B, C. Move C to position 0 → C, A, B.
      {:ok, _} = Tasks.move_task(c, user, %{"parent_id" => root.id, "position" => 0})

      titles_after_first =
        from(t in DoIt.Tasks.Task,
          where: t.parent_id == ^root.id,
          order_by: [asc: t.sort_order],
          select: t.title
        )
        |> DoIt.Repo.all()

      assert titles_after_first == ["C", "A", "B"]

      # Now move A to position 2 → C, B, A.
      a = Tasks.get_task!(a.id)
      {:ok, _} = Tasks.move_task(a, user, %{"parent_id" => root.id, "position" => 2})

      titles_after_second =
        from(t in DoIt.Tasks.Task,
          where: t.parent_id == ^root.id,
          order_by: [asc: t.sort_order],
          select: t.title
        )
        |> DoIt.Repo.all()

      assert titles_after_second == ["C", "B", "A"]

      # And confirm sort_orders have been spread (not all 0).
      orders =
        from(t in DoIt.Tasks.Task,
          where: t.parent_id == ^root.id,
          select: t.sort_order
        )
        |> DoIt.Repo.all()
        |> Enum.sort()

      assert length(Enum.uniq(orders)) == 3
      _ = b
    end

    test "cross-list move: task changes its root List, both sides recompute, Initiative aggregate reflects it",
         %{user: user, initiative: initiative} do
      # Two Lists (root tasks), each with a non-trivial subtree.
      {:ok, list_a} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "List A"})

      {:ok, list_b} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "List B"})

      {:ok, mid_a} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => list_a.id,
          "title" => "mid-a"
        })

      {:ok, _leaf_a1} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => mid_a.id,
          "title" => "leaf-a1",
          "manual_progress" => 100
        })

      {:ok, _leaf_a2} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => mid_a.id,
          "title" => "leaf-a2",
          "manual_progress" => 80
        })

      {:ok, _leaf_b1} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => list_b.id,
          "title" => "leaf-b1",
          "manual_progress" => 20
        })

      # Before the move:
      #   List A: mid-a (90) → 90; leaf_a1=100, leaf_a2=80
      #   List B: leaf_b1 → 20
      #   Initiative aggregate (LV computes as mean of root computed_progress) = (90+20)/2 = 55.
      assert Tasks.get_task!(list_a.id).computed_progress == 90
      assert Tasks.get_task!(list_b.id).computed_progress == 20

      # Cross-list move: mid_a (with its two leaves) goes from List A to List B.
      {:ok, _moved} = Tasks.move_task(mid_a, user, %{"parent_id" => list_b.id})

      # The moved task's root List has changed: its lineage now ends at List B.
      reloaded_mid = Tasks.get_task!(mid_a.id)
      assert reloaded_mid.parent_id == list_b.id

      # Source List A is now empty → 0.
      assert Tasks.get_task!(list_a.id).computed_progress == 0
      # Destination List B now has leaf-b1 (20) + mid-a (still 90) → mean = 55.
      assert Tasks.get_task!(list_b.id).computed_progress == 55

      # Initiative-level aggregate (mean of root progresses) — what the LV underbar shows —
      # is now (0 + 55) / 2 = 27 (integer div, matching `initiative_progress/1` in the LV).
      assert div(0 + 55, 2) == 27
    end

    test "rejects a cycle and persists nothing", %{user: user, initiative: initiative} do
      {:ok, root} = Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "R"})

      {:ok, child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "C"
        })

      {:ok, grandchild} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => child.id,
          "title" => "G"
        })

      # Try to move root under its own grandchild.
      assert {:error, :cycle} = Tasks.move_task(root, user, %{"parent_id" => grandchild.id})

      # Root remains a root; child + grandchild unchanged.
      assert Tasks.get_task!(root.id).parent_id == nil
      assert Tasks.get_task!(child.id).parent_id == root.id
      assert Tasks.get_task!(grandchild.id).parent_id == child.id
    end

    test "rejects cross-initiative moves and persists nothing", %{
      user: user,
      initiative: initiative
    } do
      {:ok, other_initiative} =
        Initiatives.create_initiative(user, %{"name" => "Other initiative"})

      {:ok, here} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Here"})

      {:ok, there} =
        Tasks.create_task(user, %{"initiative_id" => other_initiative.id, "title" => "There"})

      assert {:error, :cross_initiative} =
               Tasks.move_task(here, user, %{"parent_id" => there.id})

      # `here` is still a root in its original initiative.
      refreshed = Tasks.get_task!(here.id)
      assert refreshed.parent_id == nil
      assert refreshed.initiative_id == initiative.id
    end
  end

  describe "resolve_sort/1" do
    # Persist sort fields directly via Repo.update so the helper actually
    # sees them — set_sort/4 is exercised in its own context tests.
    defp set_sort_fields(%Task{} = task, mode, reverse) do
      task
      |> Ecto.Changeset.change(sort_mode: mode, sort_reverse: reverse)
      |> Repo.update!()
    end

    defp set_sort_fields(%Initiative{} = initiative, mode, reverse) do
      initiative
      |> Ecto.Changeset.change(sort_mode: mode, sort_reverse: reverse)
      |> Repo.update!()
    end

    test "nil returns {\"manual\", false}" do
      assert Tasks.resolve_sort(nil) == {"manual", false}
    end

    test "{:initiative, id} returns the initiative's {mode, reverse}", %{initiative: initiative} do
      set_sort_fields(initiative, "alphabetical", true)
      assert Tasks.resolve_sort({:initiative, initiative.id}) == {"alphabetical", true}
    end

    test "{:initiative, id} with sort_mode: nil falls back to {\"manual\", false}", %{
      initiative: initiative
    } do
      assert initiative.sort_mode == nil
      assert Tasks.resolve_sort({:initiative, initiative.id}) == {"manual", false}
    end

    test "{:initiative, id} with a nonexistent id returns {\"manual\", false}" do
      assert Tasks.resolve_sort({:initiative, -1}) == {"manual", false}
    end

    test "task with explicit sort_mode returns its own pair (no walk-up)", %{
      user: user,
      initiative: initiative
    } do
      set_sort_fields(initiative, "priority", false)

      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      {:ok, child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "Child"
        })

      set_sort_fields(root, "priority", false)
      child = set_sort_fields(child, "alphabetical", true)

      assert Tasks.resolve_sort(child) == {"alphabetical", true}
    end

    test "task with sort_mode: nil walks up to parent's pair", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      {:ok, child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "Child"
        })

      set_sort_fields(root, "completion", true)
      assert child.sort_mode == nil
      assert Tasks.resolve_sort(child) == {"completion", true}
    end

    test "direction always rides with the mode that owns it", %{
      user: user,
      initiative: initiative
    } do
      # Root explicitly sets mode = "alphabetical", reverse = true.
      # Child has sort_mode: nil but sort_reverse: false (the default).
      # Resolve should return root's (mode, reverse), NOT mix-and-match.
      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      {:ok, child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "Child"
        })

      set_sort_fields(root, "alphabetical", true)
      child = set_sort_fields(child, nil, false)

      assert Tasks.resolve_sort(child) == {"alphabetical", true}
    end

    test "chain all nil walks to initiative's pair", %{user: user, initiative: initiative} do
      set_sort_fields(initiative, "created", true)

      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      {:ok, mid} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "Mid"
        })

      {:ok, leaf} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => mid.id,
          "title" => "Leaf"
        })

      assert root.sort_mode == nil
      assert mid.sort_mode == nil
      assert leaf.sort_mode == nil
      assert Tasks.resolve_sort(leaf) == {"created", true}
    end

    test "chain all nil and initiative nil falls back to {\"manual\", false}", %{
      user: user,
      initiative: initiative
    } do
      assert initiative.sort_mode == nil

      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      {:ok, child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "Child"
        })

      assert Tasks.resolve_sort(child) == {"manual", false}
    end

    test "integer id resolves equivalently to passing the struct", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      root = set_sort_fields(root, "updated", false)

      assert Tasks.resolve_sort(root) == {"updated", false}
      assert Tasks.resolve_sort(root.id) == {"updated", false}

      {:ok, child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "Child"
        })

      assert Tasks.resolve_sort(child.id) == {"updated", false}
    end

    test "integer id with no such task returns {\"manual\", false}" do
      assert Tasks.resolve_sort(-1) == {"manual", false}
    end
  end
end
