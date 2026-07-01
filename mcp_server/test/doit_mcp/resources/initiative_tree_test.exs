defmodule DoitMcp.Resources.InitiativeTreeTest do
  use ExUnit.Case, async: true

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

    assert Jason.decode!(response.contents["text"]) == tree
  end
end
