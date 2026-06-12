defmodule DoIt.Tasks.PreviewTest do
  @moduledoc """
  Tests for `DoIt.Tasks.preview_create/2` and `DoIt.Tasks.preview_move/3`.

  These functions dry-run a create or move via a transaction rollback,
  snapshot ancestor-chain progress before and after, and classify whether
  the action would auto-flip an ancestor's status.

  Return shape:
    {:ok, %{scenario: 1 | 2 | 3 | nil, titles: [String.t()]}}
    | {:error, reason}

  Scenarios:
    1 — some ancestor(s) would go done → open ("would uncomplete")
    2 — some ancestor(s) would go open → done ("would complete")
    3 — both directions happen in the same action
    nil — no completion-state flip

  Crucially, previews must NOT persist anything — the rollback is the point.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Tasks.Task

  defp setup_user_and_initiative(_) do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Preview initiative"})

    %{user: user, initiative: initiative}
  end

  setup :setup_user_and_initiative

  # Capture every task's id/parent_id/status/manual_progress/computed_progress
  # for the given initiative. Used to assert "nothing changed".
  defp snapshot_initiative(initiative_id) do
    from(t in Task,
      where: t.initiative_id == ^initiative_id,
      order_by: [asc: t.id],
      select: %{
        id: t.id,
        parent_id: t.parent_id,
        status: t.status,
        manual_progress: t.manual_progress,
        computed_progress: t.computed_progress,
        sort_order: t.sort_order,
        title: t.title
      }
    )
    |> DoIt.Repo.all()
  end

  describe "preview_move/3 — scenario classification" do
    test "returns scenario nil when the move wouldn't flip any ancestor", %{
      user: user,
      initiative: initiative
    } do
      # Two roots, each with one incomplete leaf. Moving a leaf across keeps
      # both chains incomplete (neither flips to/from done).
      {:ok, root_a} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "A"})

      {:ok, root_b} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "B"})

      {:ok, leaf_a} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "leaf-a",
          "manual_progress" => 30
        })

      {:ok, _leaf_b} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_b.id,
          "title" => "leaf-b",
          "manual_progress" => 10
        })

      before = snapshot_initiative(initiative.id)
      before_count = length(before)

      assert {:ok, %{scenario: nil, titles: []}} =
               Tasks.preview_move(leaf_a, user, %{"parent_id" => root_b.id})

      # Nothing persisted.
      assert snapshot_initiative(initiative.id) == before
      assert before_count == length(snapshot_initiative(initiative.id))
    end

    test "returns scenario nil when an ancestor already sits at progress=100 with status=open (no crossing)",
         %{user: user, initiative: initiative} do
      # Legitimate transient state per ProductSpec: branches reach 100 once
      # all leaves do, but status may not have flipped yet. A subsequent
      # no-op or unrelated move must NOT be classified as "would complete"
      # — the threshold isn't being crossed, the parent was already there.
      {:ok, parent} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "P"})

      {:ok, _l1} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "l1",
          "status" => "done"
        })

      {:ok, l2} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => parent.id,
          "title" => "l2",
          "status" => "done"
        })

      # Auto-reconcile flipped parent to done. Manually revert to mimic
      # the (status=open, progress=100) transient.
      Tasks.get_task!(parent.id)
      |> Ecto.Changeset.change(status: "open")
      |> DoIt.Repo.update!()

      parent = Tasks.get_task!(parent.id)
      assert parent.status == "open"
      assert parent.computed_progress == 100

      # Drop l2 onto its current parent — true no-op semantically.
      assert {:ok, %{scenario: nil, titles: []}} =
               Tasks.preview_move(l2, user, %{"parent_id" => parent.id})
    end

    test "returns scenario 1 (uncomplete) when moving an incomplete leaf into a done parent chain",
         %{user: user, initiative: initiative} do
      # Destination chain: root_b → done leaf. Parent root_b is currently done
      # because its only child is done.
      {:ok, root_b} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "B-root"})

      {:ok, _done_leaf} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_b.id,
          "title" => "done-child",
          "status" => "done"
        })

      # Verify root_b auto-completed via existing reconcile.
      assert Tasks.get_task!(root_b.id).status == "done"

      # Source: a separate root with an incomplete leaf we'll dry-run moving.
      {:ok, root_a} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "A-root"})

      {:ok, leaf} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "incomplete-leaf",
          "manual_progress" => 0
        })

      before = snapshot_initiative(initiative.id)

      assert {:ok, %{scenario: 1, titles: titles}} =
               Tasks.preview_move(leaf, user, %{"parent_id" => root_b.id})

      assert "B-root" in titles
      assert snapshot_initiative(initiative.id) == before
    end

    test "returns scenario 2 (complete) when moving the last incomplete child out", %{
      user: user,
      initiative: initiative
    } do
      # root_a has: a done child and an incomplete child. Moving the incomplete
      # one out leaves only the done child → root_a would auto-complete.
      {:ok, root_a} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "A-root"})

      {:ok, _done_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "done-child",
          "status" => "done"
        })

      {:ok, incomplete_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "incomplete-child",
          "manual_progress" => 50
        })

      # Destination: separate root_b, currently open with no children — moving
      # an incomplete child in won't flip B (it's already open).
      {:ok, root_b} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "B-root"})

      # Sanity: root_a is open (still has an incomplete child).
      assert Tasks.get_task!(root_a.id).status == "open"

      before = snapshot_initiative(initiative.id)

      assert {:ok, %{scenario: 2, titles: titles}} =
               Tasks.preview_move(incomplete_child, user, %{"parent_id" => root_b.id})

      assert "A-root" in titles
      assert snapshot_initiative(initiative.id) == before
    end

    test "returns scenario 3 when both directions happen", %{
      user: user,
      initiative: initiative
    } do
      # Source root_a: a done child + an incomplete child. Moving the incomplete
      # child out → root_a auto-completes (complete direction).
      # Destination root_b: currently done (only child is done). The moved
      # incomplete child arrives there → root_b auto-uncompletes (uncomplete
      # direction).
      {:ok, root_a} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "A-root"})

      {:ok, _done_a_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "done-a-child",
          "status" => "done"
        })

      {:ok, incomplete_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_a.id,
          "title" => "incomplete-child",
          "manual_progress" => 0
        })

      {:ok, root_b} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "B-root"})

      {:ok, _done_b_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root_b.id,
          "title" => "done-b-child",
          "status" => "done"
        })

      # Sanity: root_a open (incomplete child present), root_b done.
      assert Tasks.get_task!(root_a.id).status == "open"
      assert Tasks.get_task!(root_b.id).status == "done"

      before = snapshot_initiative(initiative.id)

      assert {:ok, %{scenario: 3, titles: titles}} =
               Tasks.preview_move(incomplete_child, user, %{"parent_id" => root_b.id})

      assert "A-root" in titles
      assert "B-root" in titles
      assert snapshot_initiative(initiative.id) == before
    end
  end

  describe "preview_move/3 — error paths mirror move_task/3" do
    test "returns {:error, :cross_initiative} and persists nothing", %{
      user: user,
      initiative: initiative
    } do
      {:ok, other_initiative} =
        Initiatives.create_initiative(user, %{"name" => "Other initiative"})

      {:ok, here} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Here"})

      {:ok, there} =
        Tasks.create_task(user, %{"initiative_id" => other_initiative.id, "title" => "There"})

      before_here = snapshot_initiative(initiative.id)
      before_there = snapshot_initiative(other_initiative.id)

      assert {:error, :cross_initiative} =
               Tasks.preview_move(here, user, %{"parent_id" => there.id})

      assert snapshot_initiative(initiative.id) == before_here
      assert snapshot_initiative(other_initiative.id) == before_there
    end

    test "returns {:error, :cycle} and persists nothing", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "R"})

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

      before = snapshot_initiative(initiative.id)

      assert {:error, :cycle} =
               Tasks.preview_move(root, user, %{"parent_id" => grandchild.id})

      assert snapshot_initiative(initiative.id) == before
    end
  end

  describe "preview_create/2" do
    test "returns scenario nil for a normal incomplete create", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      {:ok, _existing} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "existing",
          "manual_progress" => 30
        })

      before = snapshot_initiative(initiative.id)

      assert {:ok, %{scenario: nil, titles: []}} =
               Tasks.preview_create(user, %{
                 "initiative_id" => initiative.id,
                 "parent_id" => root.id,
                 "title" => "new-incomplete"
               })

      assert snapshot_initiative(initiative.id) == before
    end

    test "returns scenario 1 when creating an incomplete child under a done parent", %{
      user: user,
      initiative: initiative
    } do
      # Build a parent that is currently done (all children done).
      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Parent"})

      {:ok, _done_child} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "done-child",
          "status" => "done"
        })

      assert Tasks.get_task!(root.id).status == "done"

      before = snapshot_initiative(initiative.id)

      assert {:ok, %{scenario: 1, titles: titles}} =
               Tasks.preview_create(user, %{
                 "initiative_id" => initiative.id,
                 "parent_id" => root.id,
                 "title" => "new-incomplete",
                 "manual_progress" => 0
               })

      assert "Parent" in titles
      assert snapshot_initiative(initiative.id) == before
    end

    test "propagates body errors for invalid attrs", %{user: user, initiative: initiative} do
      before = snapshot_initiative(initiative.id)

      # Missing required :title triggers a changeset error.
      assert {:error, %Ecto.Changeset{}} =
               Tasks.preview_create(user, %{
                 "initiative_id" => initiative.id,
                 "parent_id" => nil
               })

      assert snapshot_initiative(initiative.id) == before
    end

    test "tolerates a slot position (item 18) and persists nothing", %{
      user: user,
      initiative: initiative
    } do
      {:ok, root} =
        Tasks.create_task(user, %{"initiative_id" => initiative.id, "title" => "Root"})

      {:ok, _a} =
        Tasks.create_task(user, %{
          "initiative_id" => initiative.id,
          "parent_id" => root.id,
          "title" => "A"
        })

      before = snapshot_initiative(initiative.id)

      # The position param drives insert_at_position inside the preview's
      # rollback; it must not error and must leave nothing behind.
      assert {:ok, %{scenario: nil}} =
               Tasks.preview_create(user, %{
                 "initiative_id" => initiative.id,
                 "parent_id" => root.id,
                 "title" => "slotted",
                 "position" => 0
               })

      assert snapshot_initiative(initiative.id) == before
    end
  end
end
