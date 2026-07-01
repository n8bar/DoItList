defmodule DoitMcp.Tools.GetInitiativeActivityTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Tools.GetInitiativeActivity
  alias Anubis.Server.Response

  test "forwards only the present optional filters as query params" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/7/activity"
      assert URI.decode_query(conn.query_string) == %{"task_id" => "3", "limit" => "10"}

      Req.Test.json(conn, %{"data" => %{"activity" => []}})
    end)

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             GetInitiativeActivity.execute(%{initiative_id: 7, task_id: 3, limit: 10}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == %{"activity" => []}
  end

  test "omits the query entirely when no optional filters are given" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.query_string == ""
      Req.Test.json(conn, %{"data" => %{"activity" => []}})
    end)

    frame = %{test: true}
    assert {:reply, response, ^frame} = GetInitiativeActivity.execute(%{initiative_id: 7}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == %{"activity" => []}
  end
end
