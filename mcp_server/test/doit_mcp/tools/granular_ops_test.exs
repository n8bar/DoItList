defmodule DoitMcp.Tools.GranularOpsTest do
  @moduledoc """
  Table-driven coverage for the "simple, single-op" granular tools: each
  builds a one-element operations list, posts it via `DoitMcp.Client`, and
  reduces the result through `DoitMcp.ToolResult.reply/2`. This file checks
  that each tool builds the *right* op and that the reply/frame plumbing
  works — it does not re-test `Client` or `ToolResult` themselves (see
  `client_test.exs`).

  One sanctioned exception to "the first request is the POST": an
  `update_initiative` call carrying `ai_knobs` first GETs the initiative —
  the fix 23 first-write gate checks whether its knobs are still empty. The
  stub serves that read with already-set knobs so the write stays ungated
  here; the gate's own behavior lives in `update_initiative_gate_test.exs`.

  `apply_operations`, `mark_notification_read`, and `get_initiative_activity`
  are covered by their own test files and are intentionally excluded here.
  """

  use ExUnit.Case, async: true

  @cases [
    {DoitMcp.Tools.AddComment, %{task_id: 42, body: "Looks good"},
     %{"op" => "add", "type" => "comment", "data" => %{"task_id" => 42, "body" => "Looks good"}}},
    {DoitMcp.Tools.AddLink, %{source_task_id: 10, target_task_id: 20},
     %{"op" => "add", "type" => "link", "data" => %{"source_id" => 10, "target_id" => 20}}},
    {DoitMcp.Tools.AddMember, %{initiative_id: 3, user_id: 7, role: "editor"},
     %{
       "op" => "add",
       "type" => "member",
       "data" => %{"initiative_id" => 3, "user_id" => 7, "role" => "editor"}
     }},
    {DoitMcp.Tools.CompleteTask, %{task_id: 5, done: true},
     %{"op" => "update", "type" => "task", "id" => 5, "data" => %{"done" => true}}},
    {DoitMcp.Tools.CreateInitiative, %{name: "Q3 Launch"},
     %{"op" => "add", "type" => "initiative", "data" => %{"name" => "Q3 Launch"}}},
    {DoitMcp.Tools.CreateTask, %{initiative_id: 1, title: "Draft the outline"},
     %{
       "op" => "add",
       "type" => "task",
       "data" => %{"initiative_id" => 1, "title" => "Draft the outline"}
     }},
    {DoitMcp.Tools.DeleteComment, %{comment_id: 9},
     %{"op" => "remove", "type" => "comment", "id" => 9}},
    {DoitMcp.Tools.DeleteTask, %{task_id: 12}, %{"op" => "remove", "type" => "task", "id" => 12}},
    {DoitMcp.Tools.EditComment, %{comment_id: 4, body: "edited body"},
     %{"op" => "update", "type" => "comment", "id" => 4, "data" => %{"body" => "edited body"}}},
    {DoitMcp.Tools.MoveTask, %{task_id: 6, parent_id: 2},
     %{"op" => "update", "type" => "task", "id" => 6, "data" => %{"parent_id" => 2}}},
    {DoitMcp.Tools.RemoveLink, %{source_task_id: 10, target_task_id: 20},
     %{"op" => "remove", "type" => "link", "data" => %{"source_id" => 10, "target_id" => 20}}},
    {DoitMcp.Tools.RemoveMember, %{initiative_id: 3, user_id: 7},
     %{"op" => "remove", "type" => "member", "data" => %{"initiative_id" => 3, "user_id" => 7}}},
    {DoitMcp.Tools.SetInitiativeState, %{initiative_id: 3, state: "archived"},
     %{"op" => "update", "type" => "initiative", "id" => 3, "data" => %{"state" => "archived"}}},
    {DoitMcp.Tools.SetTaskCoAssignees, %{task_id: 6, co_assignee_ids: [1, 2, 3]},
     %{"op" => "update", "type" => "task", "id" => 6, "data" => %{"co_assignee_ids" => [1, 2, 3]}}},
    {DoitMcp.Tools.UpdateInitiative, %{initiative_id: 3, name: "New name"},
     %{"op" => "update", "type" => "initiative", "id" => 3, "data" => %{"name" => "New name"}}},
    {DoitMcp.Tools.UpdateInitiative, %{initiative_id: 3, ai_knobs: "deploy_day: friday"},
     %{
       "op" => "update",
       "type" => "initiative",
       "id" => 3,
       "data" => %{"ai_knobs" => "deploy_day: friday"}
     }},
    {DoitMcp.Tools.UpdateMemberRole, %{initiative_id: 3, user_id: 7, role: "viewer"},
     %{
       "op" => "update",
       "type" => "member",
       "data" => %{"initiative_id" => 3, "user_id" => 7, "role" => "viewer"}
     }},
    {DoitMcp.Tools.UpdateTask, %{task_id: 6, title: "New title"},
     %{"op" => "update", "type" => "task", "id" => 6, "data" => %{"title" => "New title"}}}
  ]

  test "update_initiative exposes the optional ai_knobs param in its input schema" do
    schema = DoitMcp.Tools.UpdateInitiative.input_schema()

    assert %{"type" => "string"} = schema["properties"]["ai_knobs"]
    refute "ai_knobs" in Map.get(schema, "required", [])
  end

  test "create_initiative's schema carries no progress_calc — creation lands the default" do
    schema = DoitMcp.Tools.CreateInitiative.input_schema()

    refute Map.has_key?(schema["properties"], "progress_calc")

    # The setting moves only via update_initiative, where the gate lives.
    update_schema = DoitMcp.Tools.UpdateInitiative.input_schema()
    assert %{"type" => "string"} = update_schema["properties"]["progress_calc"]
  end

  test "each granular tool builds its expected single op and relays the reply/frame through" do
    for {module, params, expected_op} <- @cases do
      # Only the ai_knobs-carrying update may read before posting (fix 23
      # gate); every other tool's first and only request stays the POST.
      knobs_read_allowed? = Map.has_key?(params, :ai_knobs)

      Req.Test.stub(DoitMcp.Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/initiatives/" <> _} when knobs_read_allowed? ->
            # Already-set knobs — the write is ungated, keeping this table
            # about op-building, not the gate.
            Req.Test.json(conn, %{"data" => %{"id" => 3, "ai_knobs" => "deploy_day: thursday"}})

          {"POST", "/api/v1/operations"} ->
            {:ok, body, conn} = Plug.Conn.read_body(conn)

            assert Jason.decode!(body) == %{"operations" => [expected_op]},
                   "#{inspect(module)} built the wrong op"

            Req.Test.json(conn, %{
              "results" => [%{"index" => 0, "status" => "ok", "data" => %{"id" => 1}}]
            })
        end
      end)

      frame = %{test: true}

      assert {:reply, %Anubis.Server.Response{} = response, ^frame} =
               module.execute(params, frame)

      protocol = Anubis.Server.Response.to_protocol(response)

      assert protocol["isError"] == false
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert Jason.decode!(text) == %{"id" => 1}
    end
  end
end
