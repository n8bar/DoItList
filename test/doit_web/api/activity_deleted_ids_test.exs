defmodule DoItWeb.Api.ActivityDeletedIdsTest do
  @moduledoc """
  Deletion events name the deleted child (m03.04 2.35): a `child_deleted`
  event serializes `deleted_task_id` (the deleted child) and `deleted_ids` (its
  whole subtree), derived at read time from the undo `inverse_payload` — so a
  fresh delete and a pre-existing event both answer; a degenerate payload omits
  the fields without crashing the read; `inverse_payload` itself never crosses.
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
      Initiatives.create_initiative(owner, %{"name" => "Deleted ids"}, agent_access: true)

    {:ok, {plaintext, _tok}} = Accounts.mint_api_token(owner, "planning agent")
    %{owner: owner, ini: ini, plaintext: plaintext}
  end

  test "a fresh branch delete names the child and its whole subtree", ctx do
    branch = create_task!(ctx.owner, ctx.ini, ctx.ini.root_task_id, "Branch")
    leaf_a = create_task!(ctx.owner, ctx.ini, branch.id, "Leaf A")
    leaf_b = create_task!(ctx.owner, ctx.ini, branch.id, "Leaf B")

    {:ok, _} = Tasks.delete_task(branch, ctx.owner)

    event =
      ctx.plaintext |> activity(ctx.ini.id) |> Enum.find(&(&1["kind"] == "child_deleted"))

    # The event stays on the parent's timeline; the derived fields name the child.
    assert event["task_id"] == ctx.ini.root_task_id
    assert event["deleted_task_id"] == branch.id
    assert Enum.sort(event["deleted_ids"]) == Enum.sort([branch.id, leaf_a.id, leaf_b.id])
    refute Map.has_key?(event, "inverse_payload")
  end

  test "a pre-existing event answers from its stored undo payload", ctx do
    legacy =
      Repo.insert!(%ActivityEvent{
        task_id: ctx.ini.root_task_id,
        initiative_id: ctx.ini.id,
        user_id: ctx.owner.id,
        kind: "child_deleted",
        data: %{"title" => "Long gone"},
        inverse_payload: %{"task_id" => 424_242, "deleted_ids" => [424_242, 424_243]}
      })

    event = ctx.plaintext |> activity(ctx.ini.id) |> Enum.find(&(&1["id"] == legacy.id))
    assert event["deleted_task_id"] == 424_242
    assert event["deleted_ids"] == [424_242, 424_243]
    refute Map.has_key?(event, "inverse_payload")
  end

  test "a degenerate payload omits the fields without crashing the read", ctx do
    no_payload =
      Repo.insert!(%ActivityEvent{
        task_id: ctx.ini.root_task_id,
        initiative_id: ctx.ini.id,
        user_id: ctx.owner.id,
        kind: "child_deleted",
        data: %{"title" => "Payloadless"},
        inverse_payload: nil
      })

    wrong_shape =
      Repo.insert!(%ActivityEvent{
        task_id: ctx.ini.root_task_id,
        initiative_id: ctx.ini.id,
        user_id: ctx.owner.id,
        kind: "child_deleted",
        data: %{"title" => "Odd shape"},
        inverse_payload: %{"unexpected" => true}
      })

    events = activity(ctx.plaintext, ctx.ini.id)

    for id <- [no_payload.id, wrong_shape.id] do
      event = Enum.find(events, &(&1["id"] == id))
      refute Map.has_key?(event, "deleted_task_id")
      refute Map.has_key?(event, "deleted_ids")
      refute Map.has_key?(event, "inverse_payload")
    end
  end
end
