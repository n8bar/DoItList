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

  defp park(user, attrs \\ %{}) do
    {:ok, approval} =
      ImportApprovals.park(
        user,
        Map.merge(
          %{
            "payload_hash" => @hash,
            "task_count" => 20,
            "initiative_name" => "TermiWeb"
          },
          attrs
        )
      )

    approval
  end

  @sample %{
    "nodes" => [
      %{"title" => "Milestone 3", "description" => nil, "depth" => 1},
      %{"title" => "Worklist 2", "description" => nil, "depth" => 2},
      %{"title" => "Wire the adapter", "description" => "Deduped per batch.", "depth" => 3}
    ]
  }

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
    # One card serves every parked family now (m03.04 2.8.5.3), so it states
    # the stop, not one family's reason.
    assert card =~ "Import incoming"
    assert card =~ "20 tasks are ready for import"
    assert card =~ "Reject if anything looks off"
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

    view
    |> element("#import-approval-card-#{approval.id} form")
    |> render_submit(%{"approval_id" => approval.id, "reason" => ""})

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
    assert render_submit(second, "dismiss_import", %{"approval_id" => to_string(approval.id)}) =~
             "already decided"

    assert ImportApprovals.latest_by_hash(ctx.me, @hash).status == "approved"
  end

  describe "the snapshot and the rejection reason (m03.04 3.1.9.2)" do
    test "the card shows the parked batch's sample, deepest branch and all" do
      user = user("sampler")
      approval = park(user, %{"sample" => @sample})

      {:ok, view, _html} = live(log_in(build_conn(), user), ~p"/account")

      sample = view |> element("#import-approval-sample-#{approval.id}") |> render()
      assert sample =~ "Milestone 3"
      assert sample =~ "Worklist 2"
      assert sample =~ "Wire the adapter"
      assert sample =~ "Deduped per batch."
    end

    test "a parked row with no sample renders no snapshot block" do
      user = user("nosample")
      approval = park(user)

      {:ok, view, _html} = live(log_in(build_conn(), user), ~p"/account")

      refute has_element?(view, "#import-approval-sample-#{approval.id}")
      assert has_element?(view, "#import-approval-card-#{approval.id}")
    end

    test "rejecting stores the operator's words; blank stores none" do
      user = user("rejecter")
      approval = park(user)

      {:ok, view, _html} = live(log_in(build_conn(), user), ~p"/account")

      view
      |> element("#import-approval-card-#{approval.id} form")
      |> render_submit(%{"approval_id" => approval.id, "reason" => "  Not my files.  "})

      stored = ImportApprovals.latest_by_hash(user, @hash)
      assert stored.status == "dismissed"
      assert stored.decision_reason == "Not my files."

      # A blank reason collapses to nil rather than an empty quote.
      other = user("blankrejecter")
      other_approval = park(other)
      {:ok, other_view, _html} = live(log_in(build_conn(), other), ~p"/account")

      other_view
      |> element("#import-approval-card-#{other_approval.id} form")
      |> render_submit(%{"approval_id" => other_approval.id, "reason" => "   "})

      assert ImportApprovals.latest_by_hash(other, @hash).decision_reason == nil
    end
  end

end
