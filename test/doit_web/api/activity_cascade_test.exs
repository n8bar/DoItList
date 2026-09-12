defmodule DoItWeb.Api.ActivityCascadeTest do
  @moduledoc """
  Status events suppress no-ops and expose the cascade (m03.04 2.10.3):
  completing an already-done task records nothing and writes nothing (the
  Initiative 64 done→done noise); a recorded `status_changed` serializes
  `cascaded_ids` — the other tasks the flip carried along — derived at read
  time from the undo `inverse_payload`, which itself never crosses; `[]` pins
  a single-task flip; a legacy/degenerate payload omits the field.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Repo
  alias DoIt.Tasks.ActivityEvent

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

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  # The serialized activity list for `ini_id`, read with `token`.
  defp activity(token, ini_id) do
    build_conn()
    |> bearer(token)
    |> get(~p"/api/v1/initiatives/#{ini_id}/activity?limit=200")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp create_task!(owner, ini, parent_id, title) do
    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => parent_id,
        "title" => title
      })

    task
  end

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Cascade"}, agent_access: true)

    {:ok, {plaintext, _tok}} = Accounts.mint_api_token(owner, "planning agent")
    %{owner: owner, ini: ini, plaintext: plaintext}
  end

  defp status_events(token, ini_id),
    do: token |> activity(ini_id) |> Enum.filter(&(&1["kind"] == "status_changed"))

  test "completing an already-done task records no event and writes nothing", ctx do
    leaf = create_task!(ctx.owner, ctx.ini, ctx.ini.root_task_id, "Leaf")
    {:ok, _} = Tasks.toggle_complete(leaf, ctx.owner)

    done = Tasks.get_task(leaf.id)
    assert done.status == "done"

    # The API `done: true` path on an already-done task (Initiative 64's
    # done→done repro) — every entry a no-op, so nothing is recorded.
    {:ok, _} = Tasks.cascade_complete(done, ctx.owner)

    assert length(status_events(ctx.plaintext, ctx.ini.id)) == 1

    # No write happened either: same row, same version (item 32's rule).
    after_noop = Tasks.get_task(leaf.id)
    assert after_noop.version == done.version
    assert after_noop.updated_at == done.updated_at
    assert after_noop.status == "done"
  end

  test "a cascading completion separates the acted task from the derived flips", ctx do
    branch = create_task!(ctx.owner, ctx.ini, ctx.ini.root_task_id, "Branch")
    leaf_a = create_task!(ctx.owner, ctx.ini, branch.id, "Leaf A")
    leaf_b = create_task!(ctx.owner, ctx.ini, branch.id, "Leaf B")

    # Leaf A alone: its sibling stays open, so nothing cascades.
    {:ok, _} = Tasks.toggle_complete(leaf_a, ctx.owner)
    # Leaf B completes the branch, which completes the root — two derived flips.
    {:ok, _} = Tasks.toggle_complete(Tasks.get_task(leaf_b.id), ctx.owner)

    events = status_events(ctx.plaintext, ctx.ini.id)

    event_a = Enum.find(events, &(&1["task_id"] == leaf_a.id))
    event_b = Enum.find(events, &(&1["task_id"] == leaf_b.id))

    # Single-task flip: the field is present and pinned to [].
    assert event_a["cascaded_ids"] == []

    # Cascading flip: derived tasks only — never the acted one.
    assert Enum.sort(event_b["cascaded_ids"]) ==
             Enum.sort([branch.id, ctx.ini.root_task_id])

    refute leaf_b.id in event_b["cascaded_ids"]
    refute Map.has_key?(event_b, "inverse_payload")
  end

  test "an acted no-op with real derived flips still records; swept no-ops don't count", ctx do
    branch = create_task!(ctx.owner, ctx.ini, ctx.ini.root_task_id, "Branch")
    leaf_a = create_task!(ctx.owner, ctx.ini, branch.id, "Leaf A")
    leaf_b = create_task!(ctx.owner, ctx.ini, branch.id, "Leaf B")

    {:ok, _} = Tasks.toggle_complete(leaf_a, ctx.owner)

    # `done: false` on the still-open branch: the acted task itself is a no-op,
    # but the cascade reopens Leaf A — a real write, so the event records. The
    # untouched Leaf B (already open at 0) is swept but not counted.
    {:ok, _} = Tasks.cascade_incomplete(Tasks.get_task(branch.id), ctx.owner)

    event =
      ctx.plaintext
      |> status_events(ctx.ini.id)
      |> Enum.find(&(&1["task_id"] == branch.id))

    assert event["cascaded_ids"] == [leaf_a.id]
    refute leaf_b.id in event["cascaded_ids"]
  end

  test "legacy and degenerate payloads omit the field without crashing the read", ctx do
    # A per-task row from before the atomic-event era (m02.06 item 14).
    legacy =
      Repo.insert!(%ActivityEvent{
        task_id: ctx.ini.root_task_id,
        initiative_id: ctx.ini.id,
        user_id: ctx.owner.id,
        kind: "status_changed",
        data: %{"from" => "open", "to" => "done"},
        inverse_payload: nil
      })

    wrong_shape =
      Repo.insert!(%ActivityEvent{
        task_id: ctx.ini.root_task_id,
        initiative_id: ctx.ini.id,
        user_id: ctx.owner.id,
        kind: "status_changed",
        data: %{"from" => "open", "to" => "done"},
        inverse_payload: %{"unexpected" => true}
      })

    events = activity(ctx.plaintext, ctx.ini.id)

    for id <- [legacy.id, wrong_shape.id] do
      event = Enum.find(events, &(&1["id"] == id))
      refute Map.has_key?(event, "cascaded_ids")
      refute Map.has_key?(event, "inverse_payload")
    end
  end
end
