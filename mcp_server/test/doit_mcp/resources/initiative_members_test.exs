defmodule DoitMcp.Resources.InitiativeMembersTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Resources.InitiativeMembers

  test "read/2 fetches the initiative's members and relays the reply/frame through" do
    members = [%{"user_id" => 7, "role" => "editor"}]

    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives/42/members"

      Req.Test.json(conn, %{"data" => members})
    end)

    frame = %{test: true}

    assert {:reply, %Anubis.Server.Response{type: :resource} = response, ^frame} =
             InitiativeMembers.read(%{"params" => %{"id" => "42"}}, frame)

    assert Jason.decode!(response.contents["text"]) == members
  end
end
