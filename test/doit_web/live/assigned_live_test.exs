defmodule DoItWeb.AssignedLiveTest do
  @moduledoc """
  The Assigned-to-Me page (m02.08 worklist 1): rows render with direct/co
  distinction, the reveal toggles surface completed + archived/hidden, the
  Group-by-Initiative toggle persists to the account, and a row deep-links into
  its Initiative with the task param.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Initiatives.InitiativeMember

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
    me = user("me")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha"})
    {:ok, _} = Initiatives.add_member(ini.id, me.id, "editor")

    %{conn: log_in(conn, me), owner: owner, me: me, ini: ini}
  end

  test "renders the page heading and an assigned task row", %{
    conn: conn,
    owner: owner,
    ini: ini
  } do
    task = new_task(owner, ini, %{"title" => "Do the thing", "assignee_id" => current_id(conn)})

    {:ok, view, html} = live(conn, ~p"/assigned")

    assert html =~ "Assigned to Me"
    assert has_element?(view, "#assigned-task-#{task.id}")
  end

  test "a title's %<id> token never renders literal; the row carries the ref attribute", %{
    conn: conn,
    owner: owner,
    ini: ini
  } do
    target = new_task(owner, ini, %{"title" => "Referenced task"})

    task =
      new_task(owner, ini, %{
        "title" => "Blocked on %<#{target.id}> landing",
        "assignee_id" => current_id(conn)
      })

    {:ok, view, html} = live(conn, ~p"/assigned")

    # The stored token reaches the row HTML-escaped (never literal `%<`), so the
    # browser parses a text node — the precondition for the client-side renderer
    # (.AssignedLive -> renderCardRefEl) to swap it for the neutral glyph (5.10.3).
    refute html =~ "%<"
    assert html =~ "%&lt;#{target.id}&gt;"

    # The title span carries the attribute renderAllRefs' card selector routes on.
    assert has_element?(view, "#assigned-task-#{task.id} [data-card-ref-field]")
  end

  test "completed tasks hidden by default, revealed by the toggle", %{
    conn: conn,
    owner: owner,
    ini: ini
  } do
    me_id = current_id(conn)
    _open = new_task(owner, ini, %{"title" => "OpenOne", "assignee_id" => me_id})
    done = new_task(owner, ini, %{"title" => "DoneOne", "assignee_id" => me_id})
    {:ok, _} = Tasks.toggle_complete(done, owner)

    {:ok, view, _html} = live(conn, ~p"/assigned")

    refute has_element?(view, "#assigned-task-#{done.id}")

    view |> element("#assigned-page-show-completed") |> render_click()
    assert has_element?(view, "#assigned-task-#{done.id}")
  end

  test "Group by Initiative toggle persists to the account", %{conn: conn, me: me} do
    {:ok, view, _html} = live(conn, ~p"/assigned")

    refute Accounts.get_preferences(me).assigned_group_by_initiative

    view |> element("#assigned-page-group-by") |> render_click()

    assert Accounts.get_preferences(me).assigned_group_by_initiative
  end

  test "a row deep-links into its Initiative with the task param", %{
    conn: conn,
    owner: owner,
    ini: ini
  } do
    task = new_task(owner, ini, %{"title" => "Target", "assignee_id" => current_id(conn)})

    {:ok, view, _html} = live(conn, ~p"/assigned")

    assert view
           |> element("#assigned-task-#{task.id}")
           |> render() =~ "/initiatives/#{ini.id}?task=#{task.id}"
  end

  test "archived Initiative's tasks hidden by default, revealed by the checkbox", %{
    conn: conn,
    owner: owner,
    ini: ini,
    me: me
  } do
    task = new_task(owner, ini, %{"title" => "InArchived", "assignee_id" => me.id})
    stamp(me.id, ini.id, :archived_at)

    {:ok, view, _html} = live(conn, ~p"/assigned")
    refute has_element?(view, "#assigned-task-#{task.id}")

    view |> element("#assigned-page-show-archived-hidden") |> render_click()
    assert has_element?(view, "#assigned-task-#{task.id}")
  end

  defp current_id(conn), do: Plug.Conn.get_session(conn, :user_id)

  defp stamp(user_id, initiative_id, field) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(m in InitiativeMember,
      where: m.user_id == ^user_id and m.initiative_id == ^initiative_id
    )
    |> Repo.update_all(set: [{field, now}])
  end
end
