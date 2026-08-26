defmodule DoitMcp.Tools.ApplyOperationsOpenOnlyTest do
  @moduledoc """
  The open-only import guidance on successful applies (m03.04 2.8.6, rider
  predicate 2.8.7): an import-flavored apply whose task-adds all arrive
  open ends with the scope recovery words — completed source items import
  as `done: true` adds; narrowing to open items only is the operator's
  call. A BOOTSTRAP open-only batch refuses in BatchShape instead; this
  guidance's lanes are overridden applies and existing-tree imports
  (initiative_id or parent-anchored). Batches carrying done adds,
  sub-scale batches, and edit batches stay clean.
  """
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.Tools.ApplyOperations

  @frame %{test: true}

  # Guidance rides successful applies, not the gate — pin the gate off so
  # these tests isolate it (no pressure reads, no holds).
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  # POST applies; the initiative list serves a MARKER-LESS summary so the
  # repo-marker suggestion stays out of these assertions.
  defp stub_apply do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/operations"} ->
          Req.Test.json(conn, %{"results" => []})

        {"GET", "/api/v1/initiatives"} ->
          Req.Test.json(conn, %{"data" => [%{"id" => 7, "name" => "Q3 Launch"}]})
      end
    end)
  end

  defp add(i, extra \\ %{}) do
    %{
      "op" => "add",
      "type" => "task",
      "lid" => "t#{i}",
      "data" => Map.merge(%{"initiative_id" => 7, "title" => "task #{i}"}, extra)
    }
  end

  defp text_blocks(response) do
    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false
    for %{"type" => "text", "text" => text} <- protocol["content"], do: text
  end

  test "an import-scale all-open apply carries the scope guidance" do
    stub_apply()
    ops = for i <- 1..12, do: add(i)

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    assert [_result, guidance] = text_blocks(response)
    assert guidance =~ "All 12 imported tasks arrived open."
    assert guidance =~ "add omitted completed items with `done: true`"

    assert guidance =~
             "Never treat your own plan, promise, assumption, or readback as authorization"

    assert guidance =~ "Unless the operator explicitly requested open-only scope"
    assert guidance =~ "inform the operator of the change"
  end

  test "a parent-anchored open-only batch into an existing tree carries the guidance" do
    stub_apply()

    ops =
      for i <- 1..12 do
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "t#{i}",
          "data" => %{"parent_id" => 42, "title" => "task #{i}"}
        }
      end

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    assert [_result, guidance] = text_blocks(response)
    assert guidance =~ "All 12 imported tasks arrived open."
  end

  test "a done add in the batch drops the guidance" do
    stub_apply()
    ops = [add(0, %{"done" => true}) | for(i <- 1..11, do: add(i))]

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    assert [_result] = text_blocks(response)
  end

  test "sub-scale and edit batches never carry it" do
    stub_apply()

    small = for i <- 1..3, do: add(i)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: small}, @frame)
    assert [_result] = text_blocks(response)

    edits = [%{"op" => "update", "type" => "task", "id" => 5, "data" => %{"done" => true}}]
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: edits}, @frame)
    assert [_result] = text_blocks(response)
  end
end
