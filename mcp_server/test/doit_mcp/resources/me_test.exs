defmodule DoitMcp.Resources.MeTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Resources.Me

  test "read/2 fetches the acting user and relays the reply/frame through" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/me"

      Req.Test.json(conn, %{"data" => %{"id" => 1, "email" => "ada@example.com"}})
    end)

    frame = %{test: true}

    assert {:reply, %Anubis.Server.Response{type: :resource} = response, ^frame} =
             Me.read(%{}, frame)

    assert Jason.decode!(response.contents["text"]) == %{"id" => 1, "email" => "ada@example.com"}
  end
end
