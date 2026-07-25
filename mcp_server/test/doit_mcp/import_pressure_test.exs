defmodule DoitMcp.ImportPressureTest do
  use ExUnit.Case, async: true

  alias DoitMcp.ImportPressure

  # fresh?/1 (m03.04 3.1 iteration 3): the freshness fact rides the same
  # task_count endpoint as pressure — the response's initiative_created_at,
  # age-qualified against the trailing window. Every unreadable shape is NOT
  # fresh (fail-open to the normal bounds, recent/1's precedent).

  defp stub_created_at(value) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/7/task_count"
      # The freshness read wants the Initiative's own instant, not a window
      # count — no created_at param.
      assert conn.query_string == ""
      Req.Test.json(conn, %{"data" => %{"count" => 3, "initiative_created_at" => value}})
    end)
  end

  defp minutes_ago(minutes) do
    DateTime.utc_now() |> DateTime.add(-minutes, :minute) |> DateTime.to_iso8601()
  end

  test "an Initiative created inside the window is fresh" do
    stub_created_at(minutes_ago(5))
    assert ImportPressure.fresh?({:existing, 7})
  end

  test "an Initiative older than the window has aged out" do
    stub_created_at(minutes_ago(ImportPressure.window_minutes() + 5))
    refute ImportPressure.fresh?({:existing, 7})
  end

  test "a response without initiative_created_at is not fresh — fail-open" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      Req.Test.json(conn, %{"data" => %{"count" => 3}})
    end)

    refute ImportPressure.fresh?({:existing, 7})
  end

  test "an unparseable timestamp is not fresh — fail-open" do
    stub_created_at("yesterday-ish")
    refute ImportPressure.fresh?({:existing, 7})
  end

  test "a failed read is not fresh — fail-open" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(500)
      |> Req.Test.json(%{"error" => %{"status" => 500, "code" => "internal"}})
    end)

    refute ImportPressure.fresh?({:existing, 7})
  end

  test "an Initiative born in this batch is fresh by definition — no HTTP" do
    # No stub registered: any request would raise on the missing stub.
    assert ImportPressure.fresh?({:in_batch, "i"})
  end
end
