defmodule DoitMcp.Tools.ConditionalWritesTest do
  @moduledoc """
  Conditional writes through the adapter (m03.04 2.7.4.3, 3.4.3): every write
  tool whose target carries a `version` threads `expected_version` into its
  one-op batch, a 409 conflict reply surfaces the message PLUS the current
  record, and the `expected_version` parameter carries the
  read-then-conditionally-write contract in one shared wording.
  """
  use ExUnit.Case, async: false

  alias DoitMcp.ToolResult

  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  defp expect_op(expected_op) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{"operations" => [expected_op]}

      Req.Test.json(conn, %{
        "results" => [%{"index" => 0, "status" => "ok", "data" => %{"id" => 1}}]
      })
    end)
  end

  test "update_task threads expected_version into the op's data" do
    expect_op(%{
      "op" => "update",
      "type" => "task",
      "id" => 6,
      "data" => %{"title" => "New title", "expected_version" => 4}
    })

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             DoitMcp.Tools.UpdateTask.execute(
               %{task_id: 6, title: "New title", expected_version: 4},
               frame
             )

    assert Anubis.Server.Response.to_protocol(response)["isError"] == false
  end

  test "update_initiative threads expected_version into the op's data" do
    expect_op(%{
      "op" => "update",
      "type" => "initiative",
      "id" => 3,
      "data" => %{"name" => "New name", "expected_version" => 2}
    })

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             DoitMcp.Tools.UpdateInitiative.execute(
               %{initiative_id: 3, name: "New name", expected_version: 2},
               frame
             )

    assert Anubis.Server.Response.to_protocol(response)["isError"] == false
  end

  test "complete_task threads expected_version alongside done" do
    expect_op(%{
      "op" => "update",
      "type" => "task",
      "id" => 5,
      "data" => %{"done" => true, "expected_version" => 7}
    })

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             DoitMcp.Tools.CompleteTask.execute(
               %{task_id: 5, done: true, expected_version: 7},
               frame
             )

    assert Anubis.Server.Response.to_protocol(response)["isError"] == false
  end

  test "move_task threads expected_version alongside the move" do
    expect_op(%{
      "op" => "update",
      "type" => "task",
      "id" => 6,
      "data" => %{"parent_id" => 2, "position" => 0, "expected_version" => 3}
    })

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             DoitMcp.Tools.MoveTask.execute(
               %{task_id: 6, parent_id: 2, position: 0, expected_version: 3},
               frame
             )

    assert Anubis.Server.Response.to_protocol(response)["isError"] == false
  end

  test "delete_task carries expected_version as the remove op's only data" do
    expect_op(%{
      "op" => "remove",
      "type" => "task",
      "id" => 12,
      "data" => %{"expected_version" => 9}
    })

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             DoitMcp.Tools.DeleteTask.execute(%{task_id: 12, expected_version: 9}, frame)

    assert Anubis.Server.Response.to_protocol(response)["isError"] == false
  end

  test "set_initiative_state threads expected_version alongside state" do
    expect_op(%{
      "op" => "update",
      "type" => "initiative",
      "id" => 3,
      "data" => %{"state" => "archived", "expected_version" => 4}
    })

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             DoitMcp.Tools.SetInitiativeState.execute(
               %{initiative_id: 3, state: "archived", expected_version: 4},
               frame
             )

    assert Anubis.Server.Response.to_protocol(response)["isError"] == false
  end

  test "a 409 conflict reply surfaces the message plus the current record" do
    current = %{"id" => 6, "type" => "task", "title" => "Operator intent", "version" => 5}

    client_result =
      {:error,
       %{
         status: 409,
         body: %{
           "error" => %{"status" => 409, "code" => "conflict", "message" => "rolled back"},
           "results" => [
             %{
               "index" => 0,
               "status" => "error",
               "error" => %{
                 "code" => "conflict",
                 "message" => "Task 6 is at version 5 — it changed since your read.",
                 "pointer" => "expected_version",
                 "current" => current
               }
             }
           ]
         }
       }}

    frame = %{test: true}
    assert {:reply, response, ^frame} = ToolResult.reply(frame, client_result)

    protocol = Anubis.Server.Response.to_protocol(response)
    assert protocol["isError"] == true
    assert [%{"type" => "text", "text" => text}] = protocol["content"]

    assert text =~ "changed since your read"
    assert text =~ "Current record:"
    assert text =~ Jason.encode!(current)
  end

  test "each newly versioned tool surfaces a 409 with the current record (3.4.3)" do
    current = %{"id" => 6, "type" => "task", "title" => "Operator intent", "version" => 5}

    cases = [
      {DoitMcp.Tools.CompleteTask, %{task_id: 6, done: true, expected_version: 1}},
      {DoitMcp.Tools.MoveTask, %{task_id: 6, parent_id: 2, expected_version: 1}},
      {DoitMcp.Tools.DeleteTask, %{task_id: 6, expected_version: 1}},
      {DoitMcp.Tools.SetInitiativeState,
       %{initiative_id: 6, state: "archived", expected_version: 1}}
    ]

    for {module, params} <- cases do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(409)
        |> Req.Test.json(%{
          "error" => %{"status" => 409, "code" => "conflict", "message" => "rolled back"},
          "results" => [
            %{
              "index" => 0,
              "status" => "error",
              "error" => %{
                "code" => "conflict",
                "message" => "Task 6 is at version 5 — it changed since your read.",
                "pointer" => "expected_version",
                "current" => current
              }
            }
          ]
        })
      end)

      frame = %{test: true}
      assert {:reply, response, ^frame} = module.execute(params, frame)

      protocol = Anubis.Server.Response.to_protocol(response)
      assert protocol["isError"] == true, "#{inspect(module)} swallowed the conflict"
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "changed since your read"
      assert text =~ Jason.encode!(current)
    end
  end

  describe "the tool words carry the contract (32.3, 3.4.3)" do
    # Every write tool whose target carries a `version`. Tools targeting
    # records with no version (create_task, create_initiative, the comment and
    # link tools, import_text) and apply_operations, whose per-op data carries
    # its own, are deliberately absent.
    @versioned [
      DoitMcp.Tools.UpdateTask,
      DoitMcp.Tools.UpdateInitiative,
      DoitMcp.Tools.CompleteTask,
      DoitMcp.Tools.MoveTask,
      DoitMcp.Tools.DeleteTask,
      DoitMcp.Tools.SetInitiativeState
    ]

    test "every versioned write tool exposes an optional expected_version" do
      for tool <- @versioned do
        schema = tool.input_schema()

        assert %{"type" => "integer"} = schema["properties"]["expected_version"],
               "#{inspect(tool)} is missing expected_version"

        refute "expected_version" in Map.get(schema, "required", [])
      end
    end

    test "no unversioned write tool grew the parameter" do
      for tool <- [
            DoitMcp.Tools.CreateTask,
            DoitMcp.Tools.CreateInitiative,
            DoitMcp.Tools.AddComment,
            DoitMcp.Tools.EditComment,
            DoitMcp.Tools.DeleteComment,
            DoitMcp.Tools.AddLink,
            DoitMcp.Tools.RemoveLink,
            DoitMcp.Tools.ApplyOperations,
            DoitMcp.Tools.ImportText
          ] do
        refute Map.has_key?(tool.input_schema()["properties"], "expected_version"),
               "#{inspect(tool)} has no versioned target"
      end
    end

    test "the conditional-write recovery rides one shared parameter wording" do
      # m03.04 3.3: the rule sits on the `expected_version` parameter, beside
      # the field it governs, instead of repeating in the tool description.
      shared = DoitMcp.Tools.ExpectedVersion.description()

      assert shared =~ "Always pass the `version` from your latest read"
      assert shared =~ "returns the current record"
      assert shared =~ "reconcile from it before retrying"

      for tool <- @versioned do
        assert tool.input_schema()["properties"]["expected_version"]["description"] == shared,
               "#{inspect(tool)} drifted from the shared wording"
      end

      batch = DoitMcp.Tools.ApplyOperations.__description__() |> String.replace(~r/\s+/, " ")
      assert batch =~ "expected_version"
      assert batch =~ "latest read's `version`"
      assert batch =~ "reconcile"
    end
  end
end
