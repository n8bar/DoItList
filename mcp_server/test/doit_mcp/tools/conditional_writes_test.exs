defmodule DoitMcp.Tools.ConditionalWritesTest do
  @moduledoc """
  Conditional writes through the adapter (m03.04 2.7.4.3): `update_task` /
  `update_initiative` thread `expected_version` into their one-op batch, a 409
  conflict reply surfaces the message PLUS the current record, and the tool
  words carry the read-then-conditionally-write contract.
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

  describe "the tool words carry the contract (32.3)" do
    test "update_task and update_initiative schemas expose an optional expected_version" do
      for tool <- [DoitMcp.Tools.UpdateTask, DoitMcp.Tools.UpdateInitiative] do
        schema = tool.input_schema()

        assert %{"type" => "integer"} = schema["properties"]["expected_version"]
        refute "expected_version" in Map.get(schema, "required", [])
      end
    end

    test "the three descriptions state conditional-write recovery" do
      for tool <- [DoitMcp.Tools.UpdateTask, DoitMcp.Tools.UpdateInitiative] do
        description = tool.__description__() |> String.replace(~r/\s+/, " ")

        assert description =~ "expected_version"
        assert description =~ "reconcile"
        assert description =~ "before retrying"
      end

      batch = DoitMcp.Tools.ApplyOperations.__description__() |> String.replace(~r/\s+/, " ")
      assert batch =~ "expected_version"
      assert batch =~ "latest read's `version`"
      assert batch =~ "reconcile"
    end
  end
end
