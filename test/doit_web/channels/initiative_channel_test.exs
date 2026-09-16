defmodule DoItWeb.InitiativeChannelTest do
  @moduledoc """
  The browser client's live channel (m04.01 item 1.5): who may open a socket,
  who may watch an Initiative, and that a real context write reaches a joined
  client as one `"changed"` event.
  """
  # Not async: the channel runs in its own process and needs the shared sandbox.
  use DoItWeb.ChannelCase, async: false

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoItWeb.{InitiativeChannel, UserSocket}

  defp user(name) do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp connect_as(user) do
    connect(UserSocket, %{}, connect_info: %{session: %{"user_id" => user.id}})
  end

  setup do
    owner = user("owner")
    stranger = user("stranger")
    {:ok, initiative} = Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"})

    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => initiative.id,
        "parent_id" => initiative.root_task_id,
        "title" => "Ship it"
      })

    %{owner: owner, stranger: stranger, initiative: initiative, task: task}
  end

  describe "connecting" do
    test "a signed-in session opens the socket", %{owner: owner} do
      assert {:ok, socket} = connect_as(owner)
      assert socket.assigns.current_user.id == owner.id
      assert UserSocket.id(socket) == "user_socket:#{owner.id}"
    end

    test "no session is refused" do
      assert :error = connect(UserSocket, %{}, connect_info: %{session: nil})
      assert :error = connect(UserSocket, %{}, connect_info: %{session: %{}})
    end

    test "a session naming a user who no longer exists is refused", %{owner: owner} do
      assert :error =
               connect(UserSocket, %{},
                 connect_info: %{session: %{"user_id" => owner.id + 10_000}}
               )
    end

    test "a token in params is not a credential", %{owner: owner} do
      {:ok, {plaintext, _}} = Accounts.mint_api_token(owner, "test")
      assert :error = connect(UserSocket, %{"token" => plaintext}, connect_info: %{session: %{}})
    end
  end

  describe "joining" do
    test "a member joins and is told which Initiative", %{owner: owner, initiative: initiative} do
      {:ok, socket} = connect_as(owner)

      assert {:ok, %{initiative_id: id}, _socket} =
               subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      assert id == initiative.id
    end

    test "a stranger is refused", %{stranger: stranger, initiative: initiative} do
      {:ok, socket} = connect_as(stranger)

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")
    end

    test "an unknown Initiative is not found", %{owner: owner} do
      {:ok, socket} = connect_as(owner)

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, InitiativeChannel, "initiative:99999999")

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, InitiativeChannel, "initiative:nonsense")
    end

    test "agent access being off does not gate the browser", %{
      owner: owner,
      initiative: initiative
    } do
      # The per-Initiative agent-access checkbox is off by default and gates
      # agents, not a member watching their own Initiative in a browser.
      refute Initiatives.get_initiative(initiative.id).agent_access

      {:ok, socket} = connect_as(owner)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")
    end
  end

  describe "live updates" do
    setup %{owner: owner, initiative: initiative} do
      {:ok, socket} = connect_as(owner)

      {:ok, _reply, channel} =
        subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      %{channel: channel}
    end

    test "a task update reaches the client exactly once", %{owner: owner, task: task} do
      {:ok, _} = Tasks.update_task(task, owner, %{"title" => "Ship it twice"})

      assert_push "changed", %{kind: "task_updated", id: id}
      assert id == task.id
      refute_push "changed", %{}, 100
    end

    test "a new task is a create", %{owner: owner, initiative: initiative} do
      {:ok, created} =
        Tasks.create_task(owner, %{
          "initiative_id" => initiative.id,
          "parent_id" => initiative.root_task_id,
          "title" => "And another"
        })

      assert_push "changed", %{kind: "task_created", id: id}
      assert id == created.id
    end

    test "a membership change is a change too", %{
      owner: owner,
      stranger: stranger,
      initiative: initiative
    } do
      {:ok, _} = Initiatives.add_member(initiative.id, stranger.id, "viewer", owner)

      assert_push "changed", %{kind: "members_changed", id: id}
      assert id == initiative.id
    end

    test "a message this arc has no story for is ignored", %{initiative: initiative} do
      Tasks.notify_initiative_updated(initiative.id)

      refute_push "changed", %{}, 100
    end
  end

  describe "losing access mid-session" do
    setup %{owner: owner, stranger: stranger, initiative: initiative} do
      {:ok, _} = Initiatives.add_member(initiative.id, stranger.id, "viewer", owner)
      {:ok, socket} = connect_as(stranger)

      {:ok, _reply, channel} =
        subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      %{channel: channel}
    end

    test "a removed member is told once and the channel stops", %{
      owner: owner,
      stranger: stranger,
      initiative: initiative,
      channel: channel
    } do
      ref = Process.monitor(channel.channel_pid)

      {n, _} = Initiatives.remove_member(initiative.id, stranger.id, owner)
      assert n == 1

      assert_push "access_revoked", %{initiative_id: id}
      assert id == initiative.id
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
      refute_push "changed", %{}, 100
    end

    test "a membership change that leaves access alone is just a change", %{
      owner: owner,
      initiative: initiative,
      channel: channel
    } do
      other = user("other")
      {:ok, _} = Initiatives.add_member(initiative.id, other.id, "viewer", owner)

      assert_push "changed", %{kind: "members_changed"}
      assert Process.alive?(channel.channel_pid)
    end
  end

  describe "logging out" do
    test "drops the user's live sockets", %{owner: owner} do
      DoItWeb.Endpoint.subscribe("user_socket:#{owner.id}")

      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:user_id, owner.id)
      |> DoItWeb.UserAuth.log_out_user()

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "a logout with no session broadcasts nothing", %{owner: owner} do
      DoItWeb.Endpoint.subscribe("user_socket:#{owner.id}")

      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> DoItWeb.UserAuth.log_out_user()

      refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 100
    end
  end
end
