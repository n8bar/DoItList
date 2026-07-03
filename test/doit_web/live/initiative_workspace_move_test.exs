defmodule DoItWeb.InitiativeWorkspaceMoveTest do
  @moduledoc """
  The DragReorder hook pushes "move_task" with `task_id`/`parent_id` as JSON
  numbers, not strings. `parse_id/1` must accept a numeric id, or the handler's
  "never crash → reply not_found" guard silently drops every drag (no flash, no
  persist). Exercised under `:async` (the production/dev route) since the suite
  otherwise pins `:inline`.
  """
  use DoItWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Tasks.Task
  alias DoIt.Repo

  setup %{conn: conn} do
    prev = Application.get_env(:doit, :rollup_recompute)
    Application.put_env(:doit, :rollup_recompute, :async)
    on_exit(fn -> Application.put_env(:doit, :rollup_recompute, prev) end)

    n = System.unique_integer([:positive])

    {:ok, owner} =
      Accounts.register_user(%{
        "email" => "owner#{n}@e.com",
        "username" => "owner#{n}",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "M"})
    conn = conn |> Phoenix.ConnTest.init_test_session(%{}) |> Plug.Conn.put_session(:user_id, owner.id)
    %{conn: conn, owner: owner, ini: ini}
  end

  defp task(owner, ini, attrs) do
    {:ok, t} =
      Tasks.create_task(owner, attrs |> Map.put("initiative_id", ini.id) |> Map.put_new("parent_id", ini.root_task_id))

    t
  end

  test "a move_task with NUMERIC ids (as the drag hook sends) persists", %{conn: conn, owner: owner, ini: ini} do
    a = task(owner, ini, %{"title" => "A"})
    c = task(owner, ini, %{"title" => "C"})
    d = task(owner, ini, %{"title" => "D", "parent_id" => c.id})

    {:ok, view, _} = live(conn, ~p"/initiatives/#{ini.id}")

    # Integer task_id / parent_id — the exact shape DragReorder pushes.
    render_hook(view, "move_task", %{"task_id" => d.id, "parent_id" => a.id, "position" => nil, "reorder" => false})

    assert Repo.get!(Task, d.id).parent_id == a.id,
           "drag move should persist D under A; got parent #{Repo.get!(Task, d.id).parent_id}"
  end

  test "a numeric-id reorder within a parent persists", %{conn: conn, owner: owner, ini: ini} do
    p = task(owner, ini, %{"title" => "P"})
    x = task(owner, ini, %{"title" => "X", "parent_id" => p.id})
    y = task(owner, ini, %{"title" => "Y", "parent_id" => p.id})

    {:ok, view, _} = live(conn, ~p"/initiatives/#{ini.id}")

    # Reorder Y to the front of P's children (position 0).
    render_hook(view, "move_task", %{"task_id" => y.id, "parent_id" => p.id, "position" => 0, "reorder" => true})

    order = p.id |> Tasks.ordered_child_ids()
    assert order == [y.id, x.id], "reorder should place Y before X; got #{inspect(order)}"
  end
end
