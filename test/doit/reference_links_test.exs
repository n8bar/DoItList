defmodule DoIt.ReferenceLinksTest do
  @moduledoc """
  Edge-sync for the `%<id>` cross-reference notation (m03.03): the `task_links`
  edges FROM a task mirror the reference tokens embedded in its title +
  description. `DoIt.Tasks.sync_reference_links/1` reconciles the two — adding an
  edge per newly-referenced valid target, removing edges for targets no longer
  referenced — and is invoked at the `Tasks.update_task` context boundary so both
  editing surfaces (LiveView + API) keep edges in step.

  Only VALID targets earn an edge: same Initiative, not a self-reference, and a
  live (existing, not soft-deleted) task. A typo'd / foreign / dead id is
  silently dropped — it must never crash a save.
  """
  use DoIt.DataCase, async: true

  import Ecto.Query, warn: false

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.{Task, TaskLink}

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "username" => "owner-#{System.unique_integer([:positive])}",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "Test initiative"})

    %{user: user, initiative: initiative}
  end

  defp new_task(user, initiative, attrs) do
    parent_id = Map.get(attrs, "parent_id") || initiative.root_task_id

    attrs =
      attrs
      |> Map.put("initiative_id", initiative.id)
      |> Map.put("parent_id", parent_id)

    {:ok, task} = Tasks.create_task(user, attrs)
    task
  end

  # Target ids of the task_links whose source is `task`, sorted for stable
  # assertions.
  defp link_targets(%Task{id: id}) do
    from(l in TaskLink,
      where: l.source_task_id == ^id,
      order_by: l.target_task_id,
      select: l.target_task_id
    )
    |> Repo.all()
  end

  describe "sync_reference_links/1 — desired-vs-existing diff" do
    test "one token in the title creates one edge", %{user: user, initiative: ini} do
      target = new_task(user, ini, %{"title" => "Target"})
      # Create the source WITHOUT a token so create-time sync leaves it edge-less,
      # then drive the diff off an in-memory retitle — these cases isolate the
      # add/remove delta; create-path syncing has its own describe block below.
      source = new_task(user, ini, %{"title" => "plain"})
      referencing = %{source | title: "Fix the %<#{target.id}> bug"}

      assert {:ok, %{added: [added_id], removed: []}} = Tasks.sync_reference_links(referencing)
      assert added_id == target.id
      assert link_targets(source) == [target.id]
    end

    test "tokens in title AND description union into edges", %{user: user, initiative: ini} do
      a = new_task(user, ini, %{"title" => "A"})
      b = new_task(user, ini, %{"title" => "B"})

      source = new_task(user, ini, %{"title" => "plain"})

      referencing = %{
        source
        | title: "See %<#{a.id}>",
          description: "and also %<#{b.id}> for context"
      }

      assert {:ok, %{added: added, removed: []}} = Tasks.sync_reference_links(referencing)
      assert Enum.sort(added) == Enum.sort([a.id, b.id])
      assert link_targets(source) == Enum.sort([a.id, b.id])
    end

    test "re-sync after a token is removed removes that edge", %{user: user, initiative: ini} do
      target = new_task(user, ini, %{"title" => "Target"})
      source = new_task(user, ini, %{"title" => "plain"})
      referencing = %{source | title: "See %<#{target.id}>"}

      assert {:ok, %{added: [_], removed: []}} = Tasks.sync_reference_links(referencing)
      assert link_targets(source) == [target.id]

      # The caller passes the ALREADY-updated task; sync reads title/description
      # off the struct, so an in-memory retitle models a save that dropped it.
      detitled = %{source | title: "No references any more"}
      assert {:ok, %{added: [], removed: [removed_id]}} = Tasks.sync_reference_links(detitled)
      assert removed_id == target.id
      assert link_targets(source) == []
    end

    test "a duplicate token for the same target yields one edge", %{user: user, initiative: ini} do
      target = new_task(user, ini, %{"title" => "Target"})
      source = new_task(user, ini, %{"title" => "plain"})
      referencing = %{source | title: "See %<#{target.id}> and again %<#{target.id}>"}

      assert {:ok, %{added: [added_id], removed: []}} = Tasks.sync_reference_links(referencing)
      assert added_id == target.id
      assert link_targets(source) == [target.id]
    end

    test "a token to a task in ANOTHER initiative earns no edge", %{user: user, initiative: ini} do
      {:ok, other} = Initiatives.create_initiative(user, %{"name" => "Other initiative"})
      foreign = new_task(user, other, %{"title" => "Foreign"})

      source = new_task(user, ini, %{"title" => "See %<#{foreign.id}>"})

      assert {:ok, %{added: [], removed: []}} = Tasks.sync_reference_links(source)
      assert link_targets(source) == []
    end

    test "a self-reference token earns no edge", %{user: user, initiative: ini} do
      source = new_task(user, ini, %{"title" => "placeholder"})
      selfie = %{source | title: "See %<#{source.id}>"}

      assert {:ok, %{added: [], removed: []}} = Tasks.sync_reference_links(selfie)
      assert link_targets(source) == []
    end

    test "a nonexistent id token earns no edge and never crashes", %{user: user, initiative: ini} do
      source = new_task(user, ini, %{"title" => "See %<999999999> which is gone"})

      assert {:ok, %{added: [], removed: []}} = Tasks.sync_reference_links(source)
      assert link_targets(source) == []
    end

    test "a token to a soft-deleted task earns no edge", %{user: user, initiative: ini} do
      dead = new_task(user, ini, %{"title" => "Doomed"})
      {:ok, _} = Tasks.delete_task(dead, user)

      source = new_task(user, ini, %{"title" => "See %<#{dead.id}>"})

      assert {:ok, %{added: [], removed: []}} = Tasks.sync_reference_links(source)
      assert link_targets(source) == []
    end

    test "an edge whose target is still referenced is preserved, not recreated", %{
      user: user,
      initiative: ini
    } do
      keep = new_task(user, ini, %{"title" => "Keep"})
      add = new_task(user, ini, %{"title" => "Add"})

      source = new_task(user, ini, %{"title" => "plain"})
      referencing = %{source | title: "See %<#{keep.id}>"}
      assert {:ok, %{added: [_], removed: []}} = Tasks.sync_reference_links(referencing)

      [original] = Repo.all(from l in TaskLink, where: l.source_task_id == ^source.id)

      # Now reference BOTH keep and add.
      grown = %{source | title: "See %<#{keep.id}> and %<#{add.id}>"}
      assert {:ok, %{added: [added_id], removed: []}} = Tasks.sync_reference_links(grown)
      assert added_id == add.id

      # The preserved edge is the SAME row (only the diff changed — no blow-away).
      preserved =
        Repo.one(
          from l in TaskLink,
            where: l.source_task_id == ^source.id and l.target_task_id == ^keep.id
        )

      assert preserved.id == original.id
      assert link_targets(source) == Enum.sort([keep.id, add.id])
    end
  end

  describe "legacy Unicode token form" do
    test "the abandoned %⟨id⟩ form is inert — no edge, not stripped", %{
      user: user,
      initiative: ini
    } do
      # A live, same-initiative target — only the bracket syntax makes it inert.
      target = new_task(user, ini, %{"title" => "Target"})
      source = new_task(user, ini, %{"title" => "See %⟨#{target.id}⟩"})

      assert {:ok, %{added: [], removed: []}} = Tasks.sync_reference_links(source)
      assert link_targets(source) == []

      assert Tasks.reference_ids(source.title) == []
      assert Tasks.strip_reference_tokens(source.title) == source.title
    end
  end

  describe "Tasks.update_task/4 wiring" do
    test "a title update syncs reference edges at the context boundary", %{
      user: user,
      initiative: ini
    } do
      target = new_task(user, ini, %{"title" => "Target"})
      source = new_task(user, ini, %{"title" => "plain title"})
      assert link_targets(source) == []

      {:ok, updated} =
        Tasks.update_task(source, user, %{"title" => "See %<#{target.id}>"})

      assert link_targets(source) == [target.id]

      # A later save that drops the token removes the edge too.
      {:ok, _} = Tasks.update_task(updated, user, %{"title" => "no more refs"})
      assert link_targets(source) == []
    end

    test "a description update also syncs reference edges", %{user: user, initiative: ini} do
      target = new_task(user, ini, %{"title" => "Target"})
      source = new_task(user, ini, %{"title" => "Source"})

      {:ok, _} =
        Tasks.update_task(source, user, %{"description" => "context: %<#{target.id}>"})

      assert link_targets(source) == [target.id]
    end
  end

  describe "Tasks.create_task wiring" do
    test "creating a task with a valid token in its title creates the edge", %{
      user: user,
      initiative: ini
    } do
      target = new_task(user, ini, %{"title" => "Target"})
      source = new_task(user, ini, %{"title" => "New work re %<#{target.id}>"})

      assert link_targets(source) == [target.id]
    end

    test "creating a task with a token in its description also syncs", %{
      user: user,
      initiative: ini
    } do
      target = new_task(user, ini, %{"title" => "Target"})

      source =
        new_task(user, ini, %{"title" => "Fresh task", "description" => "see %<#{target.id}>"})

      assert link_targets(source) == [target.id]
    end

    test "creating a task with a foreign/invalid token creates no edge and never crashes", %{
      user: user,
      initiative: ini
    } do
      {:ok, other} = Initiatives.create_initiative(user, %{"name" => "Other initiative"})
      foreign = new_task(user, other, %{"title" => "Foreign"})

      source =
        new_task(user, ini, %{
          "title" => "Refs %<#{foreign.id}> and %<888888888>"
        })

      assert link_targets(source) == []
    end
  end
end
