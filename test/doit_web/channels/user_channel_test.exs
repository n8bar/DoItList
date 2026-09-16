defmodule DoItWeb.UserChannelTest do
  @moduledoc """
  The user's own channel (m04.01 item 4.6.2): who may join it, and that a real
  notification reaches a joined client as one `"notification"` event carrying
  the same row the read endpoint returns.
  """
  # Not async: the channel runs in its own process and needs the shared sandbox.
  use DoItWeb.ChannelCase, async: false

  alias DoIt.{Accounts, Initiatives, Notifications, Tasks}
  alias DoItWeb.{UserChannel, UserSocket}

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

  test "joins as yourself", %{owner: owner} do
    {:ok, socket} = connect_as(owner)

    assert {:ok, %{user_id: id}, _socket} =
             subscribe_and_join(socket, UserChannel, "user:#{owner.id}")

    assert id == owner.id
  end

  test "never joins as somebody else", %{owner: owner, stranger: stranger} do
    {:ok, socket} = connect_as(owner)

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, UserChannel, "user:#{stranger.id}")
  end

  test "a notification arrives as one serialised event", ctx do
    {:ok, socket} = connect_as(ctx.owner)
    {:ok, _, _socket} = subscribe_and_join(socket, UserChannel, "user:#{ctx.owner.id}")

    {:ok, _} =
      Notifications.notify(ctx.stranger.id, ctx.owner.id, "assigned", %{
        "actor_name" => "Dana",
        "task_title" => "Ship it",
        "initiative_id" => ctx.initiative.id,
        "task_id" => ctx.task.id
      })

    assert_push "notification", payload
    assert payload.kind == "assigned"
    assert payload.line == "Dana assigned you “Ship it”"
    assert payload.href == "/app/initiatives/#{ctx.initiative.id}?task=#{ctx.task.id}"
    assert payload.read == false
    assert is_integer(payload.id)
  end

  test "another user's notification never arrives here", ctx do
    {:ok, socket} = connect_as(ctx.owner)
    {:ok, _, _socket} = subscribe_and_join(socket, UserChannel, "user:#{ctx.owner.id}")

    {:ok, _} = Notifications.notify(ctx.owner.id, ctx.stranger.id, "member_added", %{})

    refute_push "notification", _payload
  end
end
