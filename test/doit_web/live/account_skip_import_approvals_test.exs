defmodule DoItWeb.AccountSkipImportApprovalsTest do
  @moduledoc """
  The import-approval ceremony's account-level off-switch (m03.04 2.8.9): a
  toggle on the account page, homed with the approval cards it silences.
  §6.2: the checkbox is the instant client-side ack (native flip); the change
  event persists the flag; a fresh mount shows the stored value. The account
  page is the flag's only write path — the API-surface pin lives in
  `DoItWeb.Api.ImportApprovalApiTest`.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.Accounts

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

  setup %{conn: conn} do
    me = user("me")
    %{conn: log_in(conn, me), me: me}
  end

  test "renders unchecked by default with the warning copy", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account")

    assert has_element?(view, "#import-ceremony-setting")
    assert has_element?(view, "#skip-import-approvals-toggle")
    refute view |> element("#skip-import-approvals-toggle") |> render() =~ "checked"

    warning = view |> element("#skip-import-approvals-warning") |> render()
    assert warning =~ "Imports no longer wait for your approval"
  end

  test "flipping it on persists and survives a reload", ctx do
    {:ok, view, _html} = live(ctx.conn, ~p"/account")

    view
    |> element("#import-ceremony-setting form")
    |> render_change(%{"skip_import_approvals" => "true"})

    assert Accounts.get_user(ctx.me.id).skip_import_approvals

    # A fresh mount renders the stored value — the toggle arrives checked.
    {:ok, reloaded, _html} = live(ctx.conn, ~p"/account")
    assert reloaded |> element("#skip-import-approvals-toggle") |> render() =~ "checked"
  end

  test "flipping it back off persists too — both lanes", ctx do
    {:ok, _} = Accounts.set_skip_import_approvals(ctx.me, true)
    {:ok, view, _html} = live(ctx.conn, ~p"/account")

    assert view |> element("#skip-import-approvals-toggle") |> render() =~ "checked"

    # An unchecked checkbox submits no key — drive the event with the real
    # browser payload (the form-driven helper would merge the rendered
    # checkbox's checked value back in).
    render_change(view, "set_skip_import_approvals", %{})

    refute Accounts.get_user(ctx.me.id).skip_import_approvals

    {:ok, reloaded, _html} = live(ctx.conn, ~p"/account")
    refute reloaded |> element("#skip-import-approvals-toggle") |> render() =~ "checked"
  end
end
