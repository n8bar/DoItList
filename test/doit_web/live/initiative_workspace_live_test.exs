defmodule DoItWeb.InitiativeWorkspaceLiveTest do
  @moduledoc """
  M02.09 WL5.3/5.4: the kept-mounted workspace LiveView serves both
  `/initiatives` (list) and `/initiatives/:id` (detail) from ONE module, so
  list<->detail is a same-module push_patch driving handle_params with NO
  remount. These tests pin the enter/leave/switch lifecycle: the process is
  kept across hops, the detail subscriptions are entered on enter and torn down
  on leave, and a re-enter reloads fresh.
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
    {:ok, alpha} = Initiatives.create_initiative(owner, %{"name" => "Alpha Initiative"})
    {:ok, beta} = Initiatives.create_initiative(owner, %{"name" => "Beta Initiative"})
    %{conn: log_in(conn, owner), owner: owner, alpha: alpha, beta: beta}
  end

  test "list mode renders the index with the always-present shell hook", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/initiatives")

    assert has_element?(view, "#workspace-root")
    assert has_element?(view, "#initiatives")
    assert has_element?(view, "#new-initiative")
    # No detail region in list mode.
    refute has_element?(view, "[id^=\"initiative-show-root\"]")
  end

  test "list<->detail is a push_patch on ONE kept-mounted process (no remount)", %{
    conn: conn,
    alpha: alpha
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives")
    pid = view.pid

    # Patch into the detail — same module, so it's a patch, not a remount.
    render_patch(view, ~p"/initiatives/#{alpha.id}")
    assert view.pid == pid
    assert has_element?(view, "#initiative-show-root-#{alpha.id}")
    assert has_element?(view, "#initiative-detail-#{alpha.id}")
    assert has_element?(view, "#task-tree")
    # The shell hook persists across the hop.
    assert has_element?(view, "#workspace-root")
    # The detail region replaced the list region.
    refute has_element?(view, "#initiatives")

    # Patch back to the list — still the same process.
    render_patch(view, ~p"/initiatives")
    assert view.pid == pid
    assert has_element?(view, "#initiatives")
    refute has_element?(view, "[id^=\"initiative-show-root\"]")
  end

  test "switching Initiatives swaps the detail (keyed per Initiative)", %{
    conn: conn,
    owner: owner,
    alpha: alpha,
    beta: beta
  } do
    a_task = new_task(owner, alpha, %{"title" => "Alpha-only task"})
    _b_task = new_task(owner, beta, %{"title" => "Beta-only task"})

    {:ok, view, _html} = live(conn, ~p"/initiatives/#{alpha.id}")
    pid = view.pid
    assert has_element?(view, "#initiative-detail-#{alpha.id}")
    assert has_element?(view, "#task-#{a_task.id}")

    render_patch(view, ~p"/initiatives/#{beta.id}")
    assert view.pid == pid
    # The keyed wrapper changed to Beta; Alpha's task is gone from the tree.
    assert has_element?(view, "#initiative-detail-#{beta.id}")
    refute has_element?(view, "#initiative-detail-#{alpha.id}")
    refute has_element?(view, "#task-#{a_task.id}")
  end

  test "detail mode renders the AI-knobs setting; a change saves it", %{
    conn: conn,
    alpha: alpha
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{alpha.id}")

    assert has_element?(view, "textarea#ai-knobs")

    view
    |> element("#ai-knobs-form")
    |> render_change(%{"ai_knobs" => "deploy_day: friday"})

    assert Initiatives.get_initiative(alpha.id).ai_knobs == "deploy_day: friday"
  end

  test "entering a detail subscribes; a live task broadcast updates the tree", %{
    conn: conn,
    owner: owner,
    alpha: alpha
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{alpha.id}")

    # Another writer adds a task; the per-Initiative subscription delivers it.
    live_task = new_task(owner, alpha, %{"title" => "Pushed live"})
    Tasks.notify_tree_changed(alpha.id, alpha.root_task_id)

    assert render(view) =~ "Pushed live"
    assert has_element?(view, "#task-#{live_task.id}")
  end

  test "leaving a detail tears the subscription down, and re-entering reloads fresh", %{
    conn: conn,
    owner: owner,
    alpha: alpha
  } do
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{alpha.id}")
    pid = view.pid

    # Back to the list — the per-Initiative subscriptions are dropped here.
    render_patch(view, ~p"/initiatives")
    assert has_element?(view, "#initiatives")

    # A task is created in the LEFT Initiative while we sit on the list. The
    # broadcast must not reach (or crash) the kept-mounted process.
    added = new_task(owner, alpha, %{"title" => "Added while away"})
    Tasks.notify_tree_changed(alpha.id, alpha.root_task_id)
    # Still alive and on the list.
    assert Process.alive?(pid)
    assert has_element?(view, "#initiatives")

    # Re-enter the detail: load_tree on enter fetches fresh, so the task added
    # while we were away is present now.
    render_patch(view, ~p"/initiatives/#{alpha.id}")
    assert view.pid == pid
    assert has_element?(view, "#task-#{added.id}")
  end

  test "a nil / forbidden Initiative ejects to the list", %{conn: conn} do
    # A non-existent id — enter_show guards it by ejecting to the list.
    assert {:error, {redirect_kind, %{to: to}}} = live(conn, ~p"/initiatives/999999")
    assert redirect_kind in [:redirect, :live_redirect]
    assert to == "/initiatives"
  end

  test "a malformed (non-integer) :id ejects to the list instead of crashing", %{conn: conn} do
    # The route matches any string, but the Initiative pk is an integer:
    # Repo.get(Initiative, "abc") would raise Ecto.Query.CastError. fetch_initiative
    # parses defensively, so these route into the same not-found eject as 999999.
    for bad <- ["abc", "12abc"] do
      assert {:error, {redirect_kind, %{to: "/initiatives"}}} = live(conn, "/initiatives/#{bad}")
      assert redirect_kind in [:redirect, :live_redirect]
    end
  end

  test "a stale sort-form replay with empty values is a no-op, not a crash", %{
    conn: conn,
    owner: owner,
    alpha: alpha
  } do
    new_task(owner, alpha, %{"title" => "A"})
    {:ok, view, _html} = live(conn, ~p"/initiatives/#{alpha.id}")

    # Seen live: a client reconnecting across a server restart replays the
    # sort form with everything empty and no pane task selected. It must not
    # take the LiveView down.
    render_change(view, "set_sort", %{"task_id" => "", "mode" => "", "_target" => ["mode"]})

    assert has_element?(view, "#workspace-root")
  end
end
