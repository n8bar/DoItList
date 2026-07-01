defmodule DoitMcp.Tools.MarkNotificationReadTest do
  use ExUnit.Case, async: true

  alias DoitMcp.Tools.MarkNotificationRead
  alias Anubis.Server.Response

  test "all: true posts a single mark-all-read op" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "operations" => [
                 %{"op" => "update", "type" => "notification", "data" => %{"all" => true}}
               ]
             }

      Req.Test.json(conn, %{
        "results" => [%{"index" => 0, "status" => "ok", "data" => %{"marked" => "all"}}]
      })
    end)

    frame = %{test: true}
    assert {:reply, response, ^frame} = MarkNotificationRead.execute(%{all: true}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == %{"marked" => "all"}
  end

  test "notification_id posts a single-target update op" do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      assert Jason.decode!(body) == %{
               "operations" => [
                 %{
                   "op" => "update",
                   "type" => "notification",
                   "id" => 55,
                   "data" => %{"read" => true}
                 }
               ]
             }

      Req.Test.json(conn, %{
        "results" => [%{"index" => 0, "status" => "ok", "data" => %{"id" => 55, "read" => true}}]
      })
    end)

    frame = %{test: true}

    assert {:reply, response, ^frame} =
             MarkNotificationRead.execute(%{notification_id: 55}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == false

    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert Jason.decode!(text) == %{"id" => 55, "read" => true}
  end

  test "neither notification_id nor all: true errors without making any HTTP call" do
    frame = %{test: true}
    assert {:reply, response, ^frame} = MarkNotificationRead.execute(%{}, frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == true

    expected_text = "Request failed: #{inspect("must supply notification_id or all: true")}"
    assert protocol["content"] == [%{"type" => "text", "text" => expected_text}]
  end
end
