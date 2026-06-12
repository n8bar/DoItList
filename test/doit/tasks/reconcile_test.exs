defmodule DoIt.Tasks.ReconcileTest do
  @moduledoc """
  Tests for the create/move reconcile split: `*_body` helpers do the
  structural work, then `reconcile_after_create/2` and
  `reconcile_after_move/4` walk the affected ancestor chain(s) to flip
  status when the child set demands it.

  On a cross-parent move, BOTH chains may reconcile — the source can
  gain completeness (lost an incomplete child), the destination can
  lose it (gained an incomplete child).

  We assert reconcile actually fired by inspecting the persisted status
  of the affected ancestors, plus by subscribing to the Initiative's
  PubSub topic and asserting reconcile events broadcast at least once.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

  defp setup_user_and_initiative(_) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "username" => "owner-#{System.unique_integer([:positive])}",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Reconcile initiative"})

    %{user: user, initiative: initiative}
  end

  setup :setup_user_and_initiative

  describe "create_task reconciliation" do
    test "creating a done child whose siblings are all done flips parent (and chain) to done",
         %{user: user, initiative: initiative} do
      # Grandparent → parent → one existing done child.
      {:ok, grandparent} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "GP"})

      {:ok, parent} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => grandparent.id,
          "title" => "P"
        })

      {:ok, _existing_done} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "existing-done",
          "status" => "done"
        })

      # Parent has one child, which is done. After the *first* done child
      # was created the reconcile would have already flipped parent to done.
      assert Tasks.get_task!(parent.id).status == "done"
      assert Tasks.get_task!(grandparent.id).status == "done"

      # Subscribe before the next mutating call so we can observe broadcasts.
      :ok = Tasks.subscribe(initiative.id)

      # Add a second done child. The parent must remain done (still all done).
      {:ok, _another_done} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "another-done",
          "status" => "done"
        })

      # Chain remains done.
      assert Tasks.get_task!(parent.id).status == "done"
      assert Tasks.get_task!(grandparent.id).status == "done"

      # We expect at least the task_created broadcast for this initiative.
      assert_receive {:task_created, _id}, 1000
    end

    test "creating a done child under an open parent flips parent to done when it's the only child",
         %{user: user, initiative: initiative} do
      {:ok, grandparent} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "GP"})

      {:ok, parent} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => grandparent.id,
          "title" => "P"
        })

      # Both are open and childless.
      assert Tasks.get_task!(parent.id).status == "open"
      assert Tasks.get_task!(grandparent.id).status == "open"

      :ok = Tasks.subscribe(initiative.id)

      {:ok, _done_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "the-only-child",
          "status" => "done"
        })

      # Reconcile must walk up: parent and grandparent both flip to done since
      # each has exactly one child that is now done.
      assert Tasks.get_task!(parent.id).status == "done"
      assert Tasks.get_task!(grandparent.id).status == "done"

      assert_receive {:task_created, _id}, 1000
    end

    test "creating an open child under a done parent auto-unchecks the parent (and chain up)",
         %{user: user, initiative: initiative} do
      # Build a done chain: GP → P → done-leaf, so GP and P are both done.
      {:ok, grandparent} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "GP"})

      {:ok, parent} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => grandparent.id,
          "title" => "P"
        })

      {:ok, _done_leaf} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "done-leaf",
          "status" => "done"
        })

      assert Tasks.get_task!(parent.id).status == "done"
      assert Tasks.get_task!(grandparent.id).status == "done"

      :ok = Tasks.subscribe(initiative.id)

      # Now create an incomplete child under the done parent.
      {:ok, _new_open} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "new-open",
          "manual_progress" => 0
        })

      # Reconcile walks up uncompleting done ancestors.
      assert Tasks.get_task!(parent.id).status == "open"
      assert Tasks.get_task!(grandparent.id).status == "open"

      assert_receive {:task_created, _id}, 1000
    end
  end

  describe "move_task reconciliation" do
    test "source chain auto-checks when the move removes its last incomplete child", %{
      user: user,
      initiative: initiative
    } do
      # Source side: GP → P → [done-child, incomplete-child].
      # Destination: separate root_b (open, empty — won't flip on receiving
      # an incomplete child).
      {:ok, grandparent} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "GP"})

      {:ok, parent} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => grandparent.id,
          "title" => "P"
        })

      {:ok, _done_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "done-child",
          "status" => "done"
        })

      {:ok, incomplete_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "incomplete-child",
          "manual_progress" => 0
        })

      {:ok, root_b} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "B-root"})

      # Sanity: source chain still open while the incomplete child is there.
      assert Tasks.get_task!(parent.id).status == "open"
      assert Tasks.get_task!(grandparent.id).status == "open"

      :ok = Tasks.subscribe(initiative.id)

      {:ok, _moved} =
        Tasks.move_task(incomplete_child, user, %{"parent_id" => root_b.id})

      # Source chain (GP → P) auto-checks; root_b stays open (its only child
      # is now the incomplete one we just moved in).
      assert Tasks.get_task!(parent.id).status == "done"
      assert Tasks.get_task!(grandparent.id).status == "done"
      assert Tasks.get_task!(root_b.id).status == "open"

      assert_receive {:task_moved, _id}, 1000
    end

    test "destination chain auto-unchecks when the move adds an incomplete child", %{
      user: user,
      initiative: initiative
    } do
      # Destination side: GP_b → P_b → done-leaf, so GP_b and P_b are done.
      # Source side: standalone open root with an incomplete leaf to move.
      {:ok, dest_gp} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "DEST-GP"})

      {:ok, dest_parent} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => dest_gp.id,
          "title" => "DEST-P"
        })

      {:ok, _dest_done_leaf} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => dest_parent.id,
          "title" => "dest-done-leaf",
          "status" => "done"
        })

      assert Tasks.get_task!(dest_parent.id).status == "done"
      assert Tasks.get_task!(dest_gp.id).status == "done"

      {:ok, source_root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "SRC-root"})

      {:ok, incomplete_leaf} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => source_root.id,
          "title" => "incomplete-leaf",
          "manual_progress" => 0
        })

      :ok = Tasks.subscribe(initiative.id)

      {:ok, _moved} =
        Tasks.move_task(incomplete_leaf, user, %{"parent_id" => dest_parent.id})

      # Destination chain auto-unchecks all the way up.
      assert Tasks.get_task!(dest_parent.id).status == "open"
      assert Tasks.get_task!(dest_gp.id).status == "open"

      assert_receive {:task_moved, _id}, 1000
    end

    test "a single move triggers reconciliation on both chains", %{
      user: user,
      initiative: initiative
    } do
      # Source side (GP_a → P_a): one done sibling + one incomplete child.
      # Moving the incomplete child out → source chain auto-completes.
      {:ok, src_gp} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "SRC-GP"})

      {:ok, src_parent} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => src_gp.id,
          "title" => "SRC-P"
        })

      {:ok, _src_done_sibling} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => src_parent.id,
          "title" => "src-done-sibling",
          "status" => "done"
        })

      {:ok, mover} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => src_parent.id,
          "title" => "mover",
          "manual_progress" => 0
        })

      # Destination side (GP_b → P_b): existing done leaf, so done chain.
      # Receiving an incomplete child → destination chain auto-uncompletes.
      {:ok, dst_gp} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "DST-GP"})

      {:ok, dst_parent} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => dst_gp.id,
          "title" => "DST-P"
        })

      {:ok, _dst_done_leaf} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => dst_parent.id,
          "title" => "dst-done-leaf",
          "status" => "done"
        })

      # Sanity baseline.
      assert Tasks.get_task!(src_parent.id).status == "open"
      assert Tasks.get_task!(src_gp.id).status == "open"
      assert Tasks.get_task!(dst_parent.id).status == "done"
      assert Tasks.get_task!(dst_gp.id).status == "done"

      :ok = Tasks.subscribe(initiative.id)

      {:ok, _moved} = Tasks.move_task(mover, user, %{"parent_id" => dst_parent.id})

      # Source chain flipped to done (lost its last incomplete child).
      assert Tasks.get_task!(src_parent.id).status == "done"
      assert Tasks.get_task!(src_gp.id).status == "done"

      # Destination chain flipped to open (gained an incomplete child).
      assert Tasks.get_task!(dst_parent.id).status == "open"
      assert Tasks.get_task!(dst_gp.id).status == "open"

      assert_receive {:task_moved, _id}, 1000
    end
  end
end
