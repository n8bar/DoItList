defmodule DoIt.Tasks.DeltaEnvelopeTest do
  @moduledoc """
  The delivery sequence and the canonical delta envelope (m04.03 items 1.1 /
  1.2): one step per committed transaction, none on a rolled-back one, and one
  `{:initiative_delta, envelope}` per Initiative per commit carrying every
  record the commit changed — including the ones the legacy tuples under-name
  (block moves, re-sorts, restores, undo, the roll-up pass).
  """
  use DoIt.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Initiatives.Initiative
  alias DoIt.Tasks.Task
  alias DoItWeb.Api.Operations

  @record_keys ~w(id title description index position parent_id depth progress manual_progress
                  status done leaf priority assignee_id co_assignee_ids comment_count
                  cross_references referenced_by sort_mode sort_reverse updated_by updated_at
                  version)a

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp task(owner, ini, title, attrs \\ %{}) do
    {:ok, t} =
      Tasks.create_task(
        owner,
        Map.merge(
          %{"initiative_id" => ini.id, "parent_id" => ini.root_task_id, "title" => title},
          attrs
        )
      )

    t
  end

  defp seq(ini), do: Repo.one!(from i in Initiative, where: i.id == ^ini.id, select: i.seq)

  # Drop every message the setup's writes fanned out, so a test asserts only
  # on the envelope of the action under test.
  defp drain do
    receive do
      _ -> drain()
    after
      0 -> :ok
    end
  end

  defp next_envelope(ini) do
    assert_receive {:initiative_delta, %{initiative_id: id} = env}, 1000
    assert id == ini.id
    env
  end

  defp upsert_ids(env), do: env.upserts |> Enum.map(& &1.id) |> Enum.sort()

  setup do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Delta"})
    parent = task(owner, ini, "Parent")
    leaf_a = task(owner, ini, "Leaf A", %{"parent_id" => parent.id})
    leaf_b = task(owner, ini, "Leaf B", %{"parent_id" => parent.id})
    :ok = Tasks.subscribe(ini.id)
    drain()
    %{owner: owner, ini: ini, parent: parent, leaf_a: leaf_a, leaf_b: leaf_b}
  end

  describe "the sequence (1.1)" do
    test "advances by exactly one per committed transaction", ctx do
      before = seq(ctx.ini)

      {:ok, _} = Tasks.update_task(ctx.leaf_a, ctx.owner, %{"title" => "Leaf A1"})
      assert seq(ctx.ini) == before + 1

      _ = task(ctx.owner, ctx.ini, "Another")
      assert seq(ctx.ini) == before + 2
    end

    test "does not advance on a dry run", ctx do
      before = seq(ctx.ini)

      {:ok, _} =
        Tasks.preview_create(ctx.owner, %{
          "initiative_id" => ctx.ini.id,
          "parent_id" => ctx.parent.id,
          "title" => "Never"
        })

      assert seq(ctx.ini) == before
      refute_receive {:initiative_delta, _}, 50
    end

    test "does not advance on a rolled-back batch", ctx do
      before = seq(ctx.ini)

      {:error, 422, _results, _top} =
        Operations.apply_batch(
          ctx.owner,
          [
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{
                "initiative_id" => ctx.ini.id,
                "parent_id" => ctx.parent.id,
                "title" => "ok"
              }
            },
            %{
              "op" => "update",
              "type" => "task",
              "id" => ctx.leaf_a.id,
              "data" => %{"title" => ""}
            }
          ],
          surface: :browser
        )

      assert seq(ctx.ini) == before
      refute_receive {:initiative_delta, _}, 50
    end

    test "a batch with two mutations is one step and one envelope", ctx do
      before = seq(ctx.ini)

      add = fn title ->
        %{
          "op" => "add",
          "type" => "task",
          "data" => %{
            "initiative_id" => ctx.ini.id,
            "parent_id" => ctx.parent.id,
            "title" => title
          }
        }
      end

      {:ok, [%{data: %{id: id1}}, %{data: %{id: id2}}], seqs} =
        Operations.apply_batch(ctx.owner, [add.("One"), add.("Two")], surface: :browser)

      assert seq(ctx.ini) == before + 1
      assert seqs == %{ctx.ini.id => before + 1}

      env = next_envelope(ctx.ini)
      assert env.seq == before + 1
      assert id1 in upsert_ids(env) and id2 in upsert_ids(env)
      refute_receive {:initiative_delta, _}, 50
    end
  end

  describe "the envelope (1.2)" do
    test "a content edit carries the record in the snapshot's node shape", ctx do
      {:ok, _} = Tasks.update_task(ctx.leaf_a, ctx.owner, %{"title" => "Leaf A1"})

      env = next_envelope(ctx.ini)
      assert env.seq == seq(ctx.ini)
      assert env.origin_key == nil and env.actor == nil
      assert env.removed == [] and env.members_changed == false

      record = Enum.find(env.upserts, &(&1.id == ctx.leaf_a.id))
      assert record.title == "Leaf A1"
      assert record.parent_id == ctx.parent.id
      assert record.position == 0 and record.depth == 1
      assert Enum.sort(Map.keys(record)) == Enum.sort(@record_keys)
      # Any task change ships the header patch: the roll-up may have moved.
      assert %{version: _, name: "Delta", progress: _, unit_count: 2} = env.initiative
    end

    test "a delete carries the whole subtree as removed", ctx do
      {:ok, _} = Tasks.delete_task(ctx.parent, ctx.owner)

      env = next_envelope(ctx.ini)
      assert Enum.sort(env.removed) == Enum.sort([ctx.parent.id, ctx.leaf_a.id, ctx.leaf_b.id])
      assert upsert_ids(env) == []
    end

    test "a block move carries every moved task", ctx do
      other = task(ctx.owner, ctx.ini, "Other parent")
      drain()

      {:ok, _} =
        Tasks.move_tasks([ctx.leaf_a, ctx.leaf_b], ctx.owner, %{
          "parent_id" => other.id,
          "position" => 0
        })

      env = next_envelope(ctx.ini)
      assert ctx.leaf_a.id in upsert_ids(env) and ctx.leaf_b.id in upsert_ids(env)

      assert Enum.all?(env.upserts, fn r ->
               r.id not in [ctx.leaf_a.id, ctx.leaf_b.id] or r.parent_id == other.id
             end)
    end

    test "a re-sort carries every re-sorted sibling", ctx do
      # Alphabetical reverse puts B before A: both siblings change place.
      {:ok, _} = Tasks.set_sort(ctx.parent, ctx.owner, "alphabetical", true)

      env = next_envelope(ctx.ini)
      assert ctx.parent.id in upsert_ids(env)
      assert ctx.leaf_a.id in upsert_ids(env) and ctx.leaf_b.id in upsert_ids(env)
      assert Enum.find(env.upserts, &(&1.id == ctx.leaf_b.id)).position == 0
    end

    test "a cascade carries every branch it re-pointed", ctx do
      branch = task(ctx.owner, ctx.ini, "Branch", %{"parent_id" => ctx.parent.id})
      _ = task(ctx.owner, ctx.ini, "Twig", %{"parent_id" => branch.id})
      {:ok, _} = Tasks.set_sort(branch, ctx.owner, "priority", false)
      drain()

      {:ok, %{branch_count: 1}} = Tasks.cascade_sort(Tasks.get_task!(ctx.parent.id), ctx.owner)

      env = next_envelope(ctx.ini)
      assert branch.id in upsert_ids(env)
      assert Enum.find(env.upserts, &(&1.id == branch.id)).sort_mode == nil
    end

    test "a restore carries the whole restored subtree", ctx do
      {:ok, _} = Tasks.delete_task(ctx.parent, ctx.owner)
      drain()
      ids = [ctx.parent.id, ctx.leaf_a.id, ctx.leaf_b.id]

      {:ok, :ok} = Tasks.restore_tasks(ids, ctx.ini.root_task_id, ctx.ini.id)

      env = next_envelope(ctx.ini)
      assert upsert_ids(env) == Enum.sort(ids)
    end

    test "undo of a delete carries the restored subtree; undo of an edit the reverted row", ctx do
      {:ok, _} = Tasks.delete_task(ctx.parent, ctx.owner)
      drain()

      {:ok, _} = Tasks.undo(ctx.owner, ctx.ini.id)
      env = next_envelope(ctx.ini)
      assert Enum.sort([ctx.parent.id, ctx.leaf_a.id, ctx.leaf_b.id]) -- upsert_ids(env) == []

      {:ok, _} =
        Tasks.update_task(Tasks.get_task!(ctx.leaf_a.id), ctx.owner, %{"title" => "Renamed"})

      drain()
      {:ok, _} = Tasks.undo(ctx.owner, ctx.ini.id)
      env = next_envelope(ctx.ini)
      assert Enum.find(env.upserts, &(&1.id == ctx.leaf_a.id)).title == "Leaf A"
    end

    test "the roll-up pass carries every ancestor whose value moved", ctx do
      # Bypass the inline recompute so the pass has work: the leaf says 100,
      # the parent still says 0.
      {1, _} =
        from(t in Task, where: t.id == ^ctx.leaf_a.id)
        |> Repo.update_all(set: [manual_progress: 100, status: "done"])

      before = seq(ctx.ini)
      :ok = Tasks.run_rollup_pass(ctx.ini.id, [ctx.leaf_a.id])

      env = next_envelope(ctx.ini)
      assert env.seq == before + 1
      assert ctx.parent.id in upsert_ids(env)
      assert Enum.find(env.upserts, &(&1.id == ctx.parent.id)).progress == 50
      assert env.initiative.progress == 50
    end

    test "a header change carries the Initiative patch and no records", ctx do
      {:ok, _} = Initiatives.update_initiative(ctx.ini, %{"name" => "Delta, renamed"})

      env = next_envelope(ctx.ini)
      assert env.upserts == [] and env.removed == []

      assert %{
               name: "Delta, renamed",
               subtitle: "",
               progress: 0,
               unit_count: 2,
               progress_calc: "leaf_average",
               index_style: "none",
               version: _
             } = env.initiative
    end

    test "a subtitle change is a header change", ctx do
      {:ok, _} = Initiatives.update_subtitle(ctx.ini, "the plan")

      env = next_envelope(ctx.ini)
      assert env.initiative.subtitle == "the plan"
    end

    test "a membership change is flagged and carries nothing else", ctx do
      other = user("other")
      {:ok, _} = Initiatives.add_member(ctx.ini.id, other.id, "viewer", ctx.owner)

      env = next_envelope(ctx.ini)
      assert env.members_changed == true
      assert env.upserts == [] and env.removed == [] and env.initiative == nil
    end

    test "origin key and actor ride the envelope when scoped", ctx do
      DoIt.Delta.with_origin(%{key: "k-1", actor: ctx.owner}, fn ->
        {:ok, _} = Tasks.update_task(ctx.leaf_a, ctx.owner, %{"title" => "Scoped"})
      end)

      env = next_envelope(ctx.ini)
      assert env.origin_key == "k-1"
      assert env.actor == %{id: ctx.owner.id, name: ctx.owner.name, username: ctx.owner.username}
    end

    test "the legacy tuples still fire, and notes never do", ctx do
      {:ok, _} = Tasks.update_task(ctx.leaf_a, ctx.owner, %{"title" => "Still here"})

      assert_receive {:task_updated, id}
      assert id == ctx.leaf_a.id
      refute_receive {:delta_note, _, _}, 50
    end
  end
end
