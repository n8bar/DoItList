defmodule DoitMcp.Resources.InitiativesTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Resources.Initiatives

  test "read/2 fetches the caller's initiatives and relays the reply/frame through" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/initiatives"

      Req.Test.json(conn, %{"data" => [%{"id" => 1, "name" => "Q3 Launch"}]})
    end)

    frame = %{test: true}

    assert {:reply, %Anubis.Server.Response{type: :resource} = response, ^frame} =
             Initiatives.read(%{}, frame)

    assert Jason.decode!(response.contents["text"]) == [%{"id" => 1, "name" => "Q3 Launch"}]
  end
end
