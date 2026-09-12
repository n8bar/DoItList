defmodule DoitMcp.Resources.InitiativesTest do
  use ExUnit.Case, async: true

  # m03.04 3.5.1 — the marker opens the text blob of a read carrying user text.
  @user_content DoitMcp.ToolResult.user_content_line()

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

    assert [@user_content, json] = String.split(response.contents["text"], "\n", parts: 2)
    assert Jason.decode!(json) == [%{"id" => 1, "name" => "Q3 Launch"}]
  end
end
