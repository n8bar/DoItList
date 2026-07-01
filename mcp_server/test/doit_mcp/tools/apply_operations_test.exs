defmodule DoitMcp.Tools.ApplyOperationsTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Tools.ApplyOperations
  alias Anubis.Server.Response

  test "full success posts the raw ops list untouched and returns ok: true with the echoed results" do
    operations = [
      %{"op" => "add", "type" => "task", "lid" => "t1", "data" => %{"title" => "x"}},
      %{"op" => "update", "type" => "task", "id" => 1, "data" => %{"done" => true}}
    ]

    results = [
      %{"index" => 0, "status" => "ok", "data" => %{"id" => 101}},
      %{"index" => 1, "status" => "ok", "data" => %{"id" => 1}}
    ]

    Req.Test.stub(DoitMcp.Client, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/operations"

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert Jason.decode!(body) == %{"operations" => operations}

      Req.Test.json(conn, %{"results" => results})
    end)

    frame = %{test: true}
    assert {:reply, response, ^frame} = ApplyOperations.execute(%{operations: operations}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == %{"ok" => true, "results" => results}
  end

  test "partial failure (422) surfaces ok: false with per-op results, and sets isError" do
    operations = [
      %{"op" => "add", "type" => "task", "lid" => "t1", "data" => %{"title" => "x"}},
      %{"op" => "update", "type" => "task", "id" => 1, "data" => %{"done" => true}}
    ]

    error = %{"code" => "unprocessable_entity", "message" => "op 1 invalid"}

    results = [
      %{"index" => 0, "status" => "ok", "data" => %{"id" => 101}},
      %{"index" => 1, "status" => "error", "error" => %{"message" => "bad"}}
    ]

    Req.Test.stub(DoitMcp.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"error" => error, "results" => results})
    end)

    frame = %{test: true}
    assert {:reply, response, ^frame} = ApplyOperations.execute(%{operations: operations}, frame)

    protocol = Response.to_protocol(response)
    # Signaled both inside the JSON body (ok: false) AND via isError, so a
    # client that only checks the protocol-level flag still sees the failure.
    assert protocol["isError"] == true

    assert [%{"type" => "text", "text" => text}] = protocol["content"]

    assert Jason.decode!(text) == %{
             "ok" => false,
             "status" => 422,
             "error" => error,
             "results" => results
           }
  end
end
