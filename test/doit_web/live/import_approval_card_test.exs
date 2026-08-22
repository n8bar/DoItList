defmodule DoItWeb.ImportApprovalCardTest do
  @moduledoc """
  The in-app import-approval card (m03.04 2.8.8): a parked open-only import
  renders its card on the account page with both actions, appears live on a
  park, and Approve / Dismiss record once and clear the pending slot. §6:
  the buttons carry `data-latch` in-flight labels (the instant, client-side
  acknowledgement for a server-gated write) and the card leaves on the ack.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, ImportApprovals}

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

  defp park(user) do
    {:ok, approval} =
      ImportApprovals.park(user, %{
        "payload_hash" => @hash,
        "task_count" => 20,
        "initiative_name" => "TermiWeb"
      })

    approval
  end

  setup %{conn: conn} do
    me = user("me")
    %{conn: log_in(conn, me), me: me}
  end

  test "a pending park renders its card with both actions and the batch's facts", ctx do
    approval = park(ctx.me)

    {:ok, view, _html} = live(ctx.conn, ~p"/account")

    assert has_element?(view, "#import-approvals #import-approval-card-#{approval.id}")
    assert has_element?(view, "#import-approval-approve-#{approval.id}")
    assert has_element?(view, "#import-approval-dismiss-#{approval.id}")

    card = view |> element("#import-approval-card-#{approval.id}") |> render()
    assert card =~ "TermiWeb"
    assert card =~ "20"
    assert card =~ "leaving the source&#39;s completed work out"
    # §6.7: both server-gated actions carry the instant in-flight latch.
    assert card =~ "data-latch"
  end

  test "a park lands live on the open account page — no refresh needed", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account")
    refute has_element?(view, "[id^='import-approval-card-']")

    approval = park(ctx.me)

    assert render(view) =~ "import-approval-card-#{approval.id}"
  end

  test "approve records the decision and clears the pending slot", ctx do
    approval = park(ctx.me)
    {:ok, view, _html} = live(ctx.conn, ~p"/account")

    view |> element("#import-approval-approve-#{approval.id}") |> render_click()

    refute has_element?(view, "#import-approval-card-#{approval.id}")
    assert ImportApprovals.latest_by_hash(ctx.me, @hash).status == "approved"
  end

  test "dismiss records the decision and clears the pending slot", ctx do
    approval = park(ctx.me)
    {:ok, view, _html} = live(ctx.conn, ~p"/account")

    view |> element("#import-approval-dismiss-#{approval.id}") |> render_click()

    refute has_element?(view, "#import-approval-card-#{approval.id}")
    assert ImportApprovals.latest_by_hash(ctx.me, @hash).status == "dismissed"
  end

  test "a decision records once: the second tab's late click flashes instead of overwriting",
       ctx do
    approval = park(ctx.me)
    {:ok, first, _} = live(ctx.conn, ~p"/account")
    {:ok, second, _} = live(ctx.conn, ~p"/account")

    first |> element("#import-approval-approve-#{approval.id}") |> render_click()

    # The decided broadcast already cleared the second tab's card; drive its
    # stale click directly to prove the guard.
    assert render_click(second, "dismiss_import", %{"id" => to_string(approval.id)}) =~
             "already decided"

    assert ImportApprovals.latest_by_hash(ctx.me, @hash).status == "approved"
  end
end
