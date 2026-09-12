defmodule DoitMcp.Resources.InitiativeTreeTest do
  use ExUnit.Case, async: true

  # m03.04 3.5.1 — the marker opens the text blob of a read carrying user text.
  @user_content DoitMcp.ToolResult.user_content_line()

  alias DoitMcp.Resources.InitiativeTree

  test "read/2 fetches the initiative's nested tree and relays the reply/frame through" do
    tree = %{
      "id" => 42,
      "name" => "Q3 Launch",
      "tasks" => [%{"id" => 1, "title" => "Draft outline"}]
    }

    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/42"

      Req.Test.json(conn, %{"data" => tree})
    end)

    frame = %{test: true}

    assert {:reply, %Anubis.Server.Response{type: :resource} = response, ^frame} =
             InitiativeTree.read(%{"params" => %{"id" => "42"}}, frame)

    assert [@user_content, json] = String.split(response.contents["text"], "\n", parts: 2)
    assert Jason.decode!(json) == tree
  end
end
