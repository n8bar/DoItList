defmodule DoitMcp.Resources.InitiativeActivityTest do
  @moduledoc """
  Covers `DoitMcp.Resources.InitiativeActivity.read/2`. `task_id`/`limit`/
  `offset` aren't reachable via a real MCP `resources/read` call today (see
  the module's moduledoc), but `read/2` still builds the outbound query
  present-only from those keys when they show up in `params` — this file
  proves that query-building logic works even though the current
  `uri_template` can't deliver those keys yet.
  """

  use ExUnit.Case, async: true

  alias DoitMcp.Resources.InitiativeActivity

  test "read/2 with only id sends no query string" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/42/activity"
      assert conn.query_string == ""

      Req.Test.json(conn, %{"data" => []})
    end)

    frame = %{test: true}

    assert {:reply, %Anubis.Server.Response{type: :resource} = response, ^frame} =
             InitiativeActivity.read(%{"params" => %{"id" => "42"}}, frame)

    assert Jason.decode!(response.contents["text"]) == []
  end

  test "read/2 builds a present-only query from task_id/limit/offset when present" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/42/activity"
      assert URI.decode_query(conn.query_string) == %{"task_id" => "7", "limit" => "5"}

      Req.Test.json(conn, %{"data" => []})
    end)

    frame = %{test: true}

    params = %{"params" => %{"id" => "42", "task_id" => "7", "limit" => "5"}}

    assert {:reply, %Anubis.Server.Response{type: :resource} = response, ^frame} =
             InitiativeActivity.read(params, frame)

    assert Jason.decode!(response.contents["text"]) == []
  end
end
