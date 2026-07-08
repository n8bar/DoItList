defmodule DoitMcp.Tools.ReadToolsTest do
  @moduledoc """
  Table-driven coverage for the read tools — tools/list twins of the read
  resources (m03.03 item 5.3): each GETs its resource twin's endpoint and
  relays the unwrapped data envelope through the reply/frame plumbing. It
  does not re-test `Client` itself (see `client_test.exs`).

  `get_initiative_activity` (the filtered read) keeps its own test file.
  """

  use ExUnit.Case, async: true

  alias Anubis.Server.Response

  @cases [
    {DoitMcp.Tools.GetInitiativeTree, %{initiative_id: 37}, "/api/v1/initiatives/37"},
    {DoitMcp.Tools.GetTaskComments, %{initiative_id: 37, task_id: 5},
     "/api/v1/initiatives/37/tasks/5/comments"},
    {DoitMcp.Tools.GetInitiativeMembers, %{initiative_id: 37}, "/api/v1/initiatives/37/members"},
    {DoitMcp.Tools.ListInitiatives, %{}, "/api/v1/initiatives"},
    {DoitMcp.Tools.GetMe, %{}, "/api/v1/me"}
  ]

  test "each read tool GETs its resource twin's path and replies with the data" do
    for {module, params, expected_path} <- @cases do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == expected_path, "#{inspect(module)} hit the wrong path"
        assert conn.query_string == ""

        Req.Test.json(conn, %{"data" => %{"id" => 37}})
      end)

      frame = %{test: true}
      assert {:reply, %Response{} = response, ^frame} = module.execute(params, frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == false
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert Jason.decode!(text) == %{"id" => 37}
    end
  end

  test "each read tool surfaces an API error as a tool error" do
    for {module, params, _path} <- @cases do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => "not_found", "message" => "not found"}})
      end)

      frame = %{test: true}
      assert {:reply, response, ^frame} = module.execute(params, frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert protocol["content"] == [%{"type" => "text", "text" => "(404) not found"}]
    end
  end

  test "each read tool exposes a JSON object input schema for tools/list" do
    for {module, _params, _path} <- @cases do
      assert %{"type" => "object"} = module.input_schema()
    end
  end
end
