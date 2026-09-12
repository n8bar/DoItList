defmodule DoItWeb.ActivityFeedProvenanceTest do
  @moduledoc """
  The task pane's activity feed marks agent-performed events (m03.04 item
  2.33): a token-borne write wears a "via <token label>" badge; a
  browser-session write does not.
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

  test "an agent-performed event wears the token badge; a browser one does not", %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Feed"})

    # Token-stamped actor, exactly as token auth produces it.
    {:ok, {plaintext, _tok}} = Accounts.mint_api_token(owner, "planning agent")
    {:ok, agent, _token_id} = Accounts.resolve_api_token(plaintext)

    {:ok, task} =
      Tasks.create_task(agent, %{
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id,
        "title" => "Agent task"
      })

    # A browser-session write on the same task — must stay badge-free.
    {:ok, _} = Tasks.update_task(task, owner, %{"title" => "Renamed by hand"})

    {:ok, view, _html} = live(log_in(conn, owner), ~p"/initiatives/#{ini.id}")
    render_hook(view, "select_task", %{"id" => to_string(task.id)})

    assert has_element?(view, "#task-activity [data-agent-event]", "via planning agent")

    # Exactly one badge: the agent's "created" event, not the browser edit.
    # Exactly one badge in the whole render: the agent's "created" event.
    # The browser edit ("Renamed by hand") must stay badge-free.
    badge_count = length(String.split(render(view), "data-agent-event")) - 1
    assert badge_count == 1
  end
end
