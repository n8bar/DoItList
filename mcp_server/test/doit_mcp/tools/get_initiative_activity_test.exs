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

  # Execution provenance (m03.04 item 2.33) rides the API payload through
  # untouched — the MCP read serves whatever the activity endpoint says.
  test "passes provenance fields through untouched" do
    event = %{
      "id" => 555,
      "kind" => "created",
      "task_id" => 101,
      "actor_kind" => "api_token",
      "api_token_id" => 3,
      "api_token_label" => "planning agent"
    }

    legacy = %{"id" => 554, "kind" => "created", "task_id" => 100, "actor_kind" => nil}

    Req.Test.stub(DoitMcp.Client, fn conn ->
      Req.Test.json(conn, %{"data" => [event, legacy]})
    end)

    frame = %{test: true}
    assert {:reply, response, ^frame} = GetInitiativeActivity.execute(%{initiative_id: 7}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == [event, legacy]
  end

  # Deletion ids (m03.04 item 2.34) likewise ride the API payload through
  # untouched — `deleted_task_id`/`deleted_ids` reach the MCP client as served.
  test "passes deletion id fields through untouched" do
    event = %{
      "id" => 556,
      "kind" => "child_deleted",
      "task_id" => 101,
      "data" => %{"title" => "Branch"},
      "deleted_task_id" => 102,
      "deleted_ids" => [102, 103, 104]
    }

    Req.Test.stub(DoitMcp.Client, fn conn ->
      Req.Test.json(conn, %{"data" => [event]})
    end)

    frame = %{test: true}
    assert {:reply, response, ^frame} = GetInitiativeActivity.execute(%{initiative_id: 7}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == [event]
  end

  # Cascade exposure (m03.04 item 2.35) likewise rides the API payload through
  # untouched — `cascaded_ids` reaches the MCP client as served.
  test "passes cascade id fields through untouched" do
    event = %{
      "id" => 557,
      "kind" => "status_changed",
      "task_id" => 101,
      "data" => %{"from" => "open", "to" => "done"},
      "cascaded_ids" => [100, 42]
    }

    Req.Test.stub(DoitMcp.Client, fn conn ->
      Req.Test.json(conn, %{"data" => [event]})
    end)

    frame = %{test: true}
    assert {:reply, response, ^frame} = GetInitiativeActivity.execute(%{initiative_id: 7}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == [event]
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
