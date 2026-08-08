defmodule DoItWeb.ImportConfirmCardTest do
  @moduledoc """
  The in-app import-confirm cards (m03.04 item 30.2): a pending confirm
  renders on its home page (Initiative workspace / account), appears live on
  a park (the card IS the notification), and the three actions — Approve /
  Correct (with text) / Hold — record once and clear the pending slot.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, ImportConfirms, Initiatives}

  @hash String.duplicate("aa", 32)

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

  defp park(user, initiative_id, readback \\ "Importing PLAN.md as 40 tasks.") do
    {:ok, confirm} =
      ImportConfirms.park(user, initiative_id, %{
        "payload_hash" => @hash,
        "readback" => readback
      })

    confirm
  end

  setup %{conn: conn} do
    me = user("me")
    {:ok, ini} = Initiatives.create_initiative(me, %{"name" => "Alpha"}, agent_access: true)
    %{conn: log_in(conn, me), me: me, ini: ini}
  end

  test "an Initiative-homed pending confirm renders its card in the workspace", ctx do
    confirm = park(ctx.me, ctx.ini.id)

    {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.ini.id}")

    assert has_element?(view, "#import-confirm-card-#{confirm.id}")
    assert has_element?(view, "#import-confirm-approve-#{confirm.id}")
    assert has_element?(view, "#import-confirm-hold-#{confirm.id}")
    assert has_element?(view, "#import-confirm-correct-form-#{confirm.id}")

    assert view |> element("#import-confirm-card-#{confirm.id}") |> render() =~
             "Importing PLAN.md as 40 tasks."
  end

  test "a park lands live on the open workspace — the card IS the notification", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.ini.id}")
    refute has_element?(view, "[id^='import-confirm-card-']")

    confirm = park(ctx.me, ctx.ini.id)

    assert render(view) =~ "import-confirm-card-#{confirm.id}"
  end

  test "approve records the decision and clears the pending slot", ctx do
    confirm = park(ctx.me, ctx.ini.id)
    {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.ini.id}")

    view |> element("#import-confirm-approve-#{confirm.id}") |> render_click()

    refute has_element?(view, "#import-confirm-card-#{confirm.id}")
    assert ImportConfirms.latest_by_hash(ctx.me, @hash).status == "approved"
  end

  test "correct records the operator's text and clears the pending slot", ctx do
    confirm = park(ctx.me, ctx.ini.id)
    {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.ini.id}")

    view
    |> form("#import-confirm-correct-form-#{confirm.id}", %{
      "corrections" => "Milestones as top-level tasks only"
    })
    |> render_submit()

    refute has_element?(view, "#import-confirm-card-#{confirm.id}")
    decided = ImportConfirms.latest_by_hash(ctx.me, @hash)
    assert decided.status == "corrected"
    assert decided.corrections == "Milestones as top-level tasks only"
  end

  test "hold records the decision and clears the pending slot", ctx do
    confirm = park(ctx.me, ctx.ini.id)
    {:ok, view, _html} = live(ctx.conn, ~p"/initiatives/#{ctx.ini.id}")

    view |> element("#import-confirm-hold-#{confirm.id}") |> render_click()

    refute has_element?(view, "#import-confirm-card-#{confirm.id}")
    assert ImportConfirms.latest_by_hash(ctx.me, @hash).status == "held"
  end

  test "a decision records once: the second tab's late click flashes instead of overwriting",
       ctx do
    confirm = park(ctx.me, ctx.ini.id)
    {:ok, first, _} = live(ctx.conn, ~p"/initiatives/#{ctx.ini.id}")
    {:ok, second, _} = live(ctx.conn, ~p"/initiatives/#{ctx.ini.id}")

    first |> element("#import-confirm-approve-#{confirm.id}") |> render_click()

    # The decided broadcast already cleared the second tab's card; drive its
    # stale click directly to prove the guard.
    assert render_click(second, "hold_import_confirm", %{"id" => to_string(confirm.id)}) =~
             "already decided"

    assert ImportConfirms.latest_by_hash(ctx.me, @hash).status == "approved"
  end

  test "an account-homed (bootstrap) confirm renders and decides on the account page", ctx do
    confirm = park(ctx.me, nil, "Bootstrapping TermiWeb: 40 tasks under a new Initiative.")

    {:ok, view, _html} = live(ctx.conn, ~p"/account")

    assert has_element?(view, "#import-confirms #import-confirm-card-#{confirm.id}")
    assert render(view) =~ "Bootstrapping TermiWeb"

    view |> element("#import-confirm-approve-#{confirm.id}") |> render_click()

    refute has_element?(view, "#import-confirm-card-#{confirm.id}")
    assert ImportConfirms.latest_by_hash(ctx.me, @hash).status == "approved"
  end

  test "a park lands live on the open account page", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account")
    refute has_element?(view, "[id^='import-confirm-card-']")

    confirm = park(ctx.me, nil)

    assert render(view) =~ "import-confirm-card-#{confirm.id}"
  end
end
