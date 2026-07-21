defmodule DoItWeb.Api.OperationsScaleTest do
  @moduledoc """
  Batch cost tracks the CHANGE, not the tree (m03.03 item 5.8.4).

  Drive 4's import saw batch durations climb 2.6s -> 14.6s as the tree grew
  toward 244 tasks — past the MCP adapter's HTTP receive timeout. The 5.8.1
  profile pinned the tree-coupled amplification on per-op broadcast fan-out
  (each `{:task_created, id}` costs every open workspace a full tree reload:
  O(batch x tree) subscriber churn); the request pipeline itself stays flat
  as the tree grows. 5.8.2 coalesces a batch's queued broadcasts to
  per-batch signals.

  This file pins both halves at drive-4 scale — a cap-sized (150-op) batch
  against a several-hundred-task tree:

    * the batch completes WELL inside the adapter's 30s receive timeout
      (5.8.1 measured ~2.8s here at 345 tasks; the bound leaves ~4x slack
      for CI noise while still failing on any tree-sized-per-op regression);
    * an open-workspace subscriber hears a per-batch handful of messages,
      not ~150 per-op ones.

  `async: false` deliberately: racing 20 parallel test cases inflates the
  batch's wall time with suite contention (a run under full parallel load
  blew the 15s connection-hold bound) — the deadline should measure the
  pipeline, not the scheduler.
  """
  use DoItWeb.ConnCase, async: false

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Tasks.Task

  # Generous cushion-within-the-cushion: far above the ~3s measured, far
  # below the adapter's 30_000ms receive timeout.
  @batch_deadline_ms 15_000

  @seed_tasks 300

  defp register(name) do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  # Seed ~n tasks under the root in a wide 2-level shape (10 branches, the
  # rest leaves spread across them) with raw insert_all — the tree's SIZE is
  # what this test needs, not per-row event history.
  defp seed_tree(owner, ini, n) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base = %{
      status: "open",
      priority: "normal",
      manual_progress: 0,
      computed_progress: 0,
      initiative_id: ini.id,
      created_by_id: owner.id,
      updated_by_id: owner.id,
      inserted_at: now,
      updated_at: now
    }

    branch_rows =
      for i <- 1..10 do
        Map.merge(base, %{title: "Seed branch #{i}", parent_id: ini.root_task_id, sort_order: i})
      end

    {_, branches} = Repo.insert_all(Task, branch_rows, returning: [:id])

    leaves_per_branch = div(n - 10, 10)

    leaf_rows =
      for {branch, bi} <- Enum.with_index(branches),
          j <- 1..leaves_per_branch do
        Map.merge(base, %{
          title: "Seed leaf #{bi}.#{j}",
          parent_id: branch.id,
          sort_order: j
        })
      end

    Repo.insert_all(Task, leaf_rows)
  end

  # A drive-4-shaped cap-sized batch: one milestone subtree built with
  # forward lid refs (arcs of ten items), plus done-cascades and comments.
  defp cap_batch(initiative_id) do
    milestone = %{
      "op" => "add",
      "type" => "task",
      "lid" => "m",
      "data" => %{"initiative_id" => initiative_id, "title" => "M99"}
    }

    adds =
      for i <- 1..141 do
        if rem(i, 10) == 1 do
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "a#{div(i - 1, 10)}",
            "data" => %{"parent_lid" => "m", "title" => "Arc #{div(i - 1, 10) + 1}"}
          }
        else
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t#{i}",
            "data" => %{"parent_lid" => "a#{div(i - 1, 10)}", "title" => "Item #{i}"}
          }
        end
      end

    item_lids = for i <- 1..141, rem(i, 10) != 1, do: "t#{i}"

    dones =
      item_lids
      |> Enum.take(5)
      |> Enum.map(
        &%{"op" => "update", "type" => "task", "lid" => &1, "data" => %{"done" => true}}
      )

    comments =
      item_lids
      |> Enum.take(-3)
      |> Enum.map(
        &%{"op" => "add", "type" => "comment", "data" => %{"task_lid" => &1, "body" => "note"}}
      )

    batch = [milestone | adds] ++ dones ++ comments
    assert length(batch) == 150
    batch
  end

  setup do
    owner = register("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Grown Tree"}, agent_access: true)

    seed_tree(owner, ini, @seed_tasks)
    %{owner: owner, ini: ini}
  end

  test "a cap-sized batch on a several-hundred-task tree finishes well inside the adapter timeout, with per-batch broadcasts",
       %{owner: owner, ini: ini} do
    assert Tasks.initiative_task_tree(ini.id) |> count_tree() >= @seed_tasks

    Tasks.subscribe(ini.id)

    {:ok, {token, _}} = Accounts.mint_api_token(owner, "scale-test")

    {elapsed_us, conn} =
      :timer.tc(fn ->
        build_conn()
        |> put_req_header("authorization", "Bearer " <> token)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/operations", %{"operations" => cap_batch(ini.id)})
      end)

    assert %{"results" => results} = json_response(conn, 200)
    assert length(results) == 150

    elapsed_ms = div(elapsed_us, 1000)

    assert elapsed_ms < @batch_deadline_ms,
           "cap-sized batch took #{elapsed_ms}ms — the fixed pipeline should stay far below " <>
             "#{@batch_deadline_ms}ms (adapter receive timeout is 30_000ms)"

    # Broadcasts are per BATCH now (5.8.2): one task_created reload signal —
    # not one per created task — no superseded task_updated patches, and one
    # comment_added per distinct commented task.
    assert_receive {:task_created, _}, 1_000
    refute_receive {:task_created, _}, 100
    refute_receive {:task_updated, _}, 10

    for _ <- 1..3, do: assert_receive({:comment_added, _}, 100)
    refute_receive {:comment_added, _}, 10
  end

  defp count_tree(tree),
    do: Enum.reduce(tree, 0, fn t, acc -> acc + 1 + count_tree(t.children) end)
end
