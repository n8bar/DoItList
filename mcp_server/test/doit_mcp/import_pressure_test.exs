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
end
