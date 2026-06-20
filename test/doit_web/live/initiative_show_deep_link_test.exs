defmodule DoItWeb.InitiativeShowDeepLinkTest do
  @moduledoc """
  Deep-link to a task (m02.08 worklist 1 item 7): opening
  `/initiatives/:id?task=<id>` pushes the client a `deep-link-task` event
  carrying the target id and its ancestor chain, so the client expands
  collapsed ancestors, selects, and scrolls. A missing/foreign task is ignored.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives, Tasks}

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

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp new_task(owner, ini, attrs) do
    {:ok, t} =
      Tasks.create_task(
        owner,
        attrs
        |> Map.put("initiative_id", ini.id)
        |> Map.put_new("parent_id", ini.root_task_id)
      )

    t
  end

  setup %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})
    %{conn: log_in(conn, owner), owner: owner, ini: ini}
  end

  test "pushes deep-link-task with the task id and its ancestor chain", %{
    conn: conn,
    owner: owner,
    ini: ini
  } do
    branch = new_task(owner, ini, %{"title" => "Branch"})
    target = new_task(owner, ini, %{"title" => "Target", "parent_id" => branch.id})

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}?task=#{target.id}")

    assert_push_event(view, "deep-link-task", %{id: id, ancestors: ancestors})
    # The id must cross to the client as a STRING: the client echoes it straight
    # back through the "select_task" hook event, whose handler runs
    # String.to_integer/1. Pushing an integer here crashed that handler, which
    # killed the LiveView and reload-looped the page.
    assert is_binary(id)
    assert id == to_string(target.id)
    # The ancestor chain includes the branch (and the system root); never the
    # target itself.
    assert branch.id in ancestors
    refute target.id in ancestors
  end

  test "ignores a task that belongs to another Initiative", %{conn: conn, owner: owner, ini: ini} do
    {:ok, other} = Initiatives.create_initiative(owner, %{"name" => "Beta"})
    foreign = new_task(owner, other, %{"title" => "Foreign"})

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}?task=#{foreign.id}")

    refute_push_event(view, "deep-link-task", %{})
  end
end
