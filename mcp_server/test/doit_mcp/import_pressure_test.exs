defmodule DoitMcp.ImportPressureTest do
  use ExUnit.Case, async: true

  alias DoitMcp.ImportPressure

  # recent/1 (m03.04 3.1 iteration 2): the DB-window pressure read behind the
  # import classifier's cumulative trigger. Every unreadable shape counts
  # zero (fail-open — the apply surfaces the real error).

  test "reads the windowed task_count for an existing Initiative" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/7/task_count"
      # The pressure read is windowed: created_at carries the window's start.
      assert conn.query_string =~ "created_at="
      Req.Test.json(conn, %{"data" => %{"count" => 17}})
    end)

    assert ImportPressure.recent({:existing, 7}) == 17
  end

  test "a response without a count is zero — fail-open" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      Req.Test.json(conn, %{"data" => %{}})
    end)

    assert ImportPressure.recent({:existing, 7}) == 0
  end

  test "a failed read is zero — fail-open" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"error" => %{"status" => 500, "code" => "internal"}})
    end)

    assert ImportPressure.recent({:existing, 7}) == 0
  end

  test "an Initiative born in this batch has no history — zero, no HTTP" do
    # No stub registered: any request would raise on the missing stub.
    assert ImportPressure.recent({:in_batch, "i"}) == 0
  end

  # snapshot/1 (m03.04 2.8.10): the SAME windowed read, now serving the
  # interview's facts too — done count, live tree size, name, declaration.

  test "snapshot carries the interview facts from the one windowed read" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.request_path == "/api/v1/initiatives/7/task_count"
      assert conn.query_string =~ "created_at="

      Req.Test.json(conn, %{
        "data" => %{
          "count" => 17,
          "done_count" => 4,
          "live_count" => 3,
          "initiative_name" => "Q3 Launch",
          "import_declaration" => %{"source_total" => 20, "source_completed" => 5}
        }
      })
    end)

    assert ImportPressure.snapshot({:existing, 7}) == %{
             recent: 17,
             recent_done: 4,
             live: 3,
             name: "Q3 Launch",
             declaration: %{"source_total" => 20, "source_completed" => 5}
           }
  end

  test "snapshot fails open field by field — live nil, declaration nil, counts zero" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      Req.Test.json(conn, %{"data" => %{"count" => 2}})
    end)

    assert ImportPressure.snapshot({:existing, 7}) == %{
             recent: 2,
             recent_done: 0,
             live: nil,
             name: nil,
             declaration: nil
           }
  end

  test "an in-batch target's snapshot is a zero tree — no HTTP" do
    assert ImportPressure.snapshot({:in_batch, "i"}) == %{
             recent: 0,
             recent_done: 0,
             live: 0,
             name: nil,
             declaration: nil
           }
  end
end
