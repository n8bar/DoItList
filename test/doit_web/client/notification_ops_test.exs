defmodule DoItWeb.Client.NotificationOpsTest do
  @moduledoc """
  The bell's mark-all-read write, end to end (m04.01 item 4.6.3).

  The bell shipped once with `{"type": "update", "entity": "notification"}` —
  a shape the operations engine has never accepted. Every open with an unread
  row answered 422, the optimistic clear rolled back, and the user got an error
  notice for a button that works. Unit tests on either side of the wire could
  not catch it, because each side was self-consistent.

  So this test stands between them. It POSTs the payload LITERALLY, exactly as
  it is written here, at the real endpoint as a real session user, and asserts
  the row comes back read. And it reads the client's own module to check the
  bytes the browser sends are these bytes — one constant, three callers
  (`assets/js/client/state/notification_ops.js`, the bell, and the browser
  harness), and no way for them to drift apart quietly.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Notifications}

  @root Path.expand("../../..", __DIR__)
  @ops_module "assets/js/client/state/notification_ops.js"

  # The engine's envelope: `op` is the verb, `type` is the entity, everything
  # else rides in `data`.
  @mark_all_read %{
    "operations" => [%{"op" => "update", "type" => "notification", "data" => %{"all" => true}}]
  }

  defp user do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "bell-#{n}@example.com",
        "username" => "bell-#{n}",
        "name" => "Bell",
        "password" => "password123"
      })

    u
  end

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  test "the bell's payload marks the caller's unread notifications read", %{conn: conn} do
    me = user()
    {:ok, mine} = Notifications.create(me.id, "assigned", %{"task_id" => 1})
    assert is_nil(mine.read_at)

    conn = conn |> sign_in(me) |> post(~p"/app/api/operations", @mark_all_read)

    assert %{"results" => [%{"index" => 0, "status" => "ok", "data" => data}]} =
             json_response(conn, 200)

    assert data["type"] == "notification"
    assert data["all"] == true
    assert data["marked_read"] == 1
    refute is_nil(Notifications.get(mine.id).read_at)
  end

  test "it touches nobody else's notifications", %{conn: conn} do
    me = user()
    someone_else = user()
    {:ok, _} = Notifications.create(me.id, "assigned", %{"task_id" => 1})
    {:ok, theirs} = Notifications.create(someone_else.id, "assigned", %{"task_id" => 2})

    conn = conn |> sign_in(me) |> post(~p"/app/api/operations", @mark_all_read)

    assert json_response(conn, 200)
    assert is_nil(Notifications.get(theirs.id).read_at)
  end

  test "the client sends exactly this payload" do
    # Read out of the client's module by running it, not by matching text: what
    # the browser posts is whatever this function returns.
    module = Path.join(@root, @ops_module)

    js =
      "import(#{inspect("file://" <> module)}).then((m) => console.log(JSON.stringify(m.markAllReadRequest())))"

    {output, status} = System.cmd("node", ["-e", js], cd: @root, stderr_to_stdout: true)

    assert status == 0, """
    could not read the client's mark-all-read payload.

    Reproduce: docker compose exec -T web node -e #{inspect(js)}

    #{output}
    """

    assert Jason.decode!(String.trim(output)) == @mark_all_read, """
    the client's payload and this test have drifted apart.

    The client sends: #{String.trim(output)}
    This test posts:  #{Jason.encode!(@mark_all_read)}
    """
  end
end
