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

  # Presence untracking is asynchronous; poll rather than sleep a fixed beat.
  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
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

    test "a bearer token is not a credential under any param name", %{owner: owner} do
      {:ok, {plaintext, _}} = Accounts.mint_api_token(owner, "test")

      for params <- [
            %{"authorization" => "Bearer " <> plaintext},
            %{"api_token" => plaintext},
            %{"_csrf_token" => plaintext},
            %{"user_id" => owner.id}
          ] do
        assert :error = connect(UserSocket, params, connect_info: %{session: %{}})
      end
    end
  end

  describe "joining" do
    test "a member joins and is told which Initiative", %{owner: owner, initiative: initiative} do
      {:ok, socket} = connect_as(owner)

      assert {:ok, %{initiative_id: id}, _socket} =
               subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      assert id == initiative.id
    end

    test "the reply carries the Initiative's delivery sequence as of the join (m04.03 3.3)", %{
      owner: owner,
      initiative: initiative,
      task: task
    } do
      {:ok, _} = Tasks.update_task(task, owner, %{"title" => "Advanced"})
      current = Initiatives.get_initiative!(initiative.id).seq
      assert current > 0

      {:ok, socket} = connect_as(owner)

      assert {:ok, %{initiative_id: id, seq: seq}, _socket} =
               subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      assert id == initiative.id
      assert seq == current
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

    test "an Initiative-record change is a change too", %{initiative: initiative} do
      Tasks.notify_initiative_updated(initiative.id)

      assert_push "changed", %{kind: "initiative_updated", id: id}
      assert id == initiative.id
    end

    test "a message this arc has no story for is ignored", %{channel: channel} do
      send(channel.channel_pid, {:something_unmodeled, 999})

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

  describe "the delta envelope (m04.03 1.3)" do
    setup %{owner: owner, initiative: initiative} do
      {:ok, socket} = connect_as(owner)

      {:ok, _reply, channel} =
        subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      %{channel: channel}
    end

    test "a committed write is pushed once as a delta, beside the legacy change", %{
      owner: owner,
      task: task,
      initiative: initiative
    } do
      {:ok, _} = Tasks.update_task(task, owner, %{"title" => "Ship it, sequenced"})

      assert_push "changed", %{kind: "task_updated"}
      assert_push "delta", %{initiative_id: id, seq: seq, upserts: upserts, removed: []}
      assert id == initiative.id
      assert seq == DoIt.Initiatives.get_initiative!(initiative.id).seq
      assert Enum.find(upserts, &(&1.id == task.id)).title == "Ship it, sequenced"
      refute_push "delta", %{}, 100
    end

    test "a membership change that leaves access alone is delivered", %{
      owner: owner,
      initiative: initiative,
      channel: channel
    } do
      other = user("other")
      {:ok, _} = Initiatives.add_member(initiative.id, other.id, "viewer", owner)

      assert_push "delta", %{members_changed: true}
      assert Process.alive?(channel.channel_pid)
    end

    test "a delta that revokes access is never delivered", %{
      owner: owner,
      stranger: stranger,
      initiative: initiative
    } do
      {:ok, _} = Initiatives.add_member(initiative.id, stranger.id, "viewer", owner)
      # The owner's channel (this describe's setup) forwards that add.
      assert_push "delta", %{members_changed: true}
      {:ok, socket} = connect_as(stranger)

      {:ok, _reply, theirs} =
        subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      ref = Process.monitor(theirs.channel_pid)

      # Drop the membership row silently, then hand the channel the envelope
      # itself: the tuple path is covered above, and this proves the
      # envelope path re-authorizes on its own before pushing records.
      import Ecto.Query, only: [from: 2]

      {1, _} =
        DoIt.Repo.delete_all(
          from(m in DoIt.Initiatives.InitiativeMember,
            where: m.initiative_id == ^initiative.id and m.user_id == ^stranger.id
          )
        )

      send(
        theirs.channel_pid,
        {:initiative_delta,
         %{initiative_id: initiative.id, seq: 99, members_changed: true, upserts: [], removed: []}}
      )

      assert_push "access_revoked", %{initiative_id: id}
      assert id == initiative.id
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
      refute_push "delta", %{}, 100
    end
  end

  describe "selection presence" do
    setup %{owner: owner, initiative: initiative} do
      {:ok, socket} = connect_as(owner)

      {:ok, _reply, channel} =
        subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      %{channel: channel}
    end

    test "join pushes the current presence state", %{owner: owner, initiative: initiative} do
      assert_push "presence_state", state
      key = to_string(owner.id)

      assert %{^key => %{metas: [meta]}} = state
      assert meta.user_id == owner.id
      assert meta.task_id == nil
      assert meta.name == owner.name
      assert is_binary(meta.initials) and is_binary(meta.bg) and is_binary(meta.fg)

      # The LiveView-side topic sees the channel's member, in the same shape.
      assert %{^key => %{metas: [^meta]}} =
               DoItWeb.Presence.list(DoItWeb.Presence.initiative_topic(initiative.id))
    end

    test "a select announces the row as a diff", %{channel: channel, owner: owner, task: task} do
      # Our own join is a diff too — take it out of the mailbox first.
      assert_push "presence_diff", %{joins: %{}}

      ref = push(channel, "select", %{"task_id" => task.id})
      assert_reply ref, :ok

      key = to_string(owner.id)
      assert_push "presence_diff", %{joins: %{^key => %{metas: [meta]}}}
      assert meta.task_id == task.id
      assert meta.user_id == owner.id

      # Clearing the selection is the same push with a null id.
      clear = push(channel, "select", %{"task_id" => nil})
      assert_reply clear, :ok
      assert_push "presence_diff", %{joins: %{^key => %{metas: [cleared]}}}
      assert cleared.task_id == nil
    end

    test "a task_id that isn't an id is refused", %{channel: channel} do
      for bad <- [%{"task_id" => "12"}, %{"task_id" => %{}}, %{}] do
        ref = push(channel, "select", bad)
        assert_reply ref, :error, %{reason: "bad_task_id"}
      end
    end

    test "a second member's arrival is a diff", %{
      owner: owner,
      stranger: other,
      initiative: initiative
    } do
      assert_push "presence_state", _state

      {:ok, _} = Initiatives.add_member(initiative.id, other.id, "viewer", owner)
      {:ok, socket} = connect_as(other)

      {:ok, _reply, _channel} =
        subscribe_and_join(socket, InitiativeChannel, "initiative:#{initiative.id}")

      key = to_string(other.id)
      assert_push "presence_diff", %{joins: %{^key => %{metas: [meta]}}}
      assert meta.user_id == other.id
    end

    test "presence ends with the channel", %{
      channel: channel,
      owner: owner,
      initiative: initiative
    } do
      assert_push "presence_state", _state
      topic = DoItWeb.Presence.initiative_topic(initiative.id)
      assert Map.has_key?(DoItWeb.Presence.list(topic), to_string(owner.id))

      # The channel is linked to this test process; unlink so its normal
      # shutdown on leave isn't an exit signal here.
      Process.unlink(channel.channel_pid)
      ref = Process.monitor(channel.channel_pid)
      Phoenix.ChannelTest.leave(channel)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}

      # Presence's own cleanup is async; wait for the topic to empty.
      assert eventually(fn -> DoItWeb.Presence.list(topic) == %{} end)
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
