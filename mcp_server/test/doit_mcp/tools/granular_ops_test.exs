defmodule DoitMcp.Tools.GranularOpsTest do
  @moduledoc """
  Table-driven coverage for the "simple, single-op" granular tools: each
  builds a one-element operations list, posts it via `DoitMcp.Client`, and
  reduces the result through `DoitMcp.ToolResult.reply/2`. This file checks
  that each tool builds the *right* op and that the reply/frame plumbing
  works — it does not re-test `Client` or `ToolResult` themselves (see
  `client_test.exs`).

  Every tool's first and only request is the POST — no tool reads before it
  writes.

  `apply_operations`, `import_text`, and `get_initiative_activity` are covered
  by their own test files and are intentionally excluded here.
  """

  use ExUnit.Case, async: false

  @cases [
    {DoitMcp.Tools.AddComment, %{task_id: 42, body: "Looks good"},
     %{"op" => "add", "type" => "comment", "data" => %{"task_id" => 42, "body" => "Looks good"}}},
    {DoitMcp.Tools.AddLink, %{source_task_id: 10, target_task_id: 20},
     %{"op" => "add", "type" => "link", "data" => %{"source_id" => 10, "target_id" => 20}}},
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
    # `done` rides the create (m03.04 2.5.4): a completed item is one op.
    {DoitMcp.Tools.CreateTask, %{initiative_id: 1, title: "Already done", done: true},
     %{
       "op" => "add",
       "type" => "task",
       "data" => %{"initiative_id" => 1, "title" => "Already done", "done" => true}
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
    {DoitMcp.Tools.SetInitiativeState, %{initiative_id: 3, state: "archived"},
     %{"op" => "update", "type" => "initiative", "id" => 3, "data" => %{"state" => "archived"}}},
    {DoitMcp.Tools.UpdateInitiative, %{initiative_id: 3, name: "New name"},
     %{"op" => "update", "type" => "initiative", "id" => 3, "data" => %{"name" => "New name"}}},
    # CALC-GATE-PARKED (m03.04): the parked-state contract — a non-default
    # progress_calc change applies ungated, with no read and no elicitation
    # (the apply-only stub below fails loudly on a read). Retire when the
    # gate revives.
    {DoitMcp.Tools.UpdateInitiative, %{initiative_id: 3, progress_calc: "single_level"},
     %{
       "op" => "update",
       "type" => "initiative",
       "id" => 3,
       "data" => %{"progress_calc" => "single_level"}
     }},
    # AI-KNOBS-PARKED (m03.04): ai_knobs off the tool; revive this case with the schema field.
    # {DoitMcp.Tools.UpdateInitiative, %{initiative_id: 3, ai_knobs: "deploy_day: friday"},
    #  %{
    #    "op" => "update",
    #    "type" => "initiative",
    #    "id" => 3,
    #    "data" => %{"ai_knobs" => "deploy_day: friday"}
    #  }},
    {DoitMcp.Tools.UpdateTask, %{task_id: 6, title: "New title"},
     %{"op" => "update", "type" => "task", "id" => 6, "data" => %{"title" => "New title"}}}
  ]

  # AI-KNOBS-PARKED (m03.04): revive with the schema field.
  @tag :skip
  test "update_initiative exposes the optional ai_knobs param in its input schema" do
    schema = DoitMcp.Tools.UpdateInitiative.input_schema()

    assert %{"type" => "string"} = schema["properties"]["ai_knobs"]
    refute "ai_knobs" in Map.get(schema, "required", [])
  end

  test "create_initiative's schema carries no progress_calc — creation lands the default" do
    schema = DoitMcp.Tools.CreateInitiative.input_schema()

    refute Map.has_key?(schema["properties"], "progress_calc")

    # The setting moves only via update_initiative.
    update_schema = DoitMcp.Tools.UpdateInitiative.input_schema()
    assert %{"type" => "string"} = update_schema["properties"]["progress_calc"]
  end

  test "each granular tool builds its expected single op and relays the reply/frame through" do
    for {module, params, expected_op} <- @cases do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        case {conn.method, conn.request_path} do
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
