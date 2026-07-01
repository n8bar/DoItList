defmodule DoitMcp.ClientTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Client

  test "get/2 sends the token as a Bearer header and unwraps the data envelope" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
      assert conn.request_path == "/api/v1/me"
      Req.Test.json(conn, %{"data" => %{"id" => 1, "email" => "ada@example.com"}})
    end)

    assert {:ok, %{"id" => 1, "email" => "ada@example.com"}} = Client.get("/api/v1/me")
  end

  test "get/2 forwards query params" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.query_string == "task_id=42&limit=5"
      Req.Test.json(conn, %{"data" => []})
    end)

    assert {:ok, []} = Client.get("/api/v1/initiatives/1/activity", task_id: 42, limit: 5)
  end

  test "operations/1 posts the ops list to /api/v1/operations and returns the results as-is" do
    ops = [%{"op" => "add", "type" => "task", "data" => %{"title" => "x"}}]

    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/operations"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"operations" => ops}

      Req.Test.json(conn, %{
        "results" => [%{"index" => 0, "status" => "ok", "data" => %{"id" => 1}}]
      })
    end)

    assert {:ok, %{"results" => [%{"status" => "ok", "data" => %{"id" => 1}}]}} =
             Client.operations(ops)
  end

  test "a non-2xx response is surfaced as {:error, %{status:, body:}}" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"error" => %{"code" => "unprocessable_entity", "message" => "bad"}})
    end)

    assert {:error, %{status: 422, body: %{"error" => %{"message" => "bad"}}}} =
             Client.get("/api/v1/me")
  end

  test "a transport-level failure is surfaced as {:error, %{reason:}}" do
    Req.Test.stub(DoitMcp.Client, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, %{reason: _}} = Client.get("/api/v1/me")
  end
end
