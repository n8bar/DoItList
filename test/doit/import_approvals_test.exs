defmodule DoIt.ImportApprovalsTest do
  @moduledoc """
  Server-verified import approvals (m03.04 2.8.8): park semantics (idempotent
  pending, dismissed latch, TTL re-park), the park's notification, the
  record-once decisions, and the adapter's read-back by hash.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, ImportApprovals, Notifications}
  alias DoIt.ImportApprovals.ImportApproval

  @hash String.duplicate("ab", 32)

  defp user(name \\ "op") do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp park(user, attrs \\ %{}) do
    ImportApprovals.park(
      user,
      Map.merge(
        %{"payload_hash" => @hash, "task_count" => 20, "initiative_name" => "TermiWeb"},
        attrs
      )
    )
  end

  defp age(approval, hours) do
    old =
      DateTime.utc_now()
      |> DateTime.add(-hours, :hour)
      |> DateTime.truncate(:second)

    {1, _} =
      Repo.update_all(
        from(a in ImportApproval, where: a.id == ^approval.id),
        set: [inserted_at: old]
      )

    :ok
  end

  test "park opens a pending row, broadcasts, and notifies the account owner" do
    me = user()
    ImportApprovals.subscribe(me.id)

    assert {:ok, approval} = park(me)
    assert approval.status == "pending"
    assert approval.task_count == 20
    assert approval.initiative_name == "TermiWeb"

    assert_receive {:import_approval_parked, %ImportApproval{id: id}}
    assert id == approval.id

    assert [notif] = Notifications.list_recent(me)
    assert notif.kind == "import_approval_requested"
    assert notif.data["initiative_name"] == "TermiWeb"
    assert notif.data["task_count"] == 20
  end

  test "park is idempotent on a standing pending row — one card, one notification" do
    me = user()

    assert {:ok, first} = park(me)
    assert {:ok, second} = park(me)

    assert second.id == first.id
    assert [_only] = ImportApprovals.list_pending_for_account(me)
    assert [_one_notif] = Notifications.list_recent(me)
  end

  test "an expired pending park re-parks fresh and re-notifies" do
    me = user()

    {:ok, first} = park(me)
    age(first, ImportApprovals.ttl_hours() + 1)

    assert {:ok, second} = park(me)
    refute second.id == first.id
    assert second.status == "pending"

    # The expired row is off the account page; the fresh one is on it.
    assert [%{id: id}] = ImportApprovals.list_pending_for_account(me)
    assert id == second.id
    assert length(Notifications.list_recent(me)) == 2
  end

  test "approve records once and broadcasts; the second decision is refused" do
    me = user()
    {:ok, approval} = park(me)
    ImportApprovals.subscribe(me.id)

    assert {:ok, decided} = ImportApprovals.decide(me, approval.id, "approved")
    assert decided.status == "approved"
    assert_receive {:import_approval_decided, %ImportApproval{status: "approved"}}

    assert {:error, :not_pending} = ImportApprovals.decide(me, approval.id, "dismissed")
    assert ImportApprovals.latest_by_hash(me, @hash).status == "approved"
    assert ImportApprovals.list_pending_for_account(me) == []
  end

  test "an approved hash reads back approved — the adapter's consult" do
    me = user()
    {:ok, approval} = park(me)
    {:ok, _} = ImportApprovals.decide(me, approval.id, "approved")

    assert %ImportApproval{status: "approved"} = ImportApprovals.latest_by_hash(me, @hash)
    # Another user's consult never sees it.
    assert ImportApprovals.latest_by_hash(user("other"), @hash) == nil
  end

  test "dismiss latches: a same-hash re-park returns the dismissed row, no fresh card" do
    me = user()
    {:ok, approval} = park(me)
    {:ok, _} = ImportApprovals.decide(me, approval.id, "dismissed")

    assert {:ok, latched} = park(me)
    assert latched.id == approval.id
    assert latched.status == "dismissed"
    assert ImportApprovals.list_pending_for_account(me) == []
    # No second notification rode the latched re-park.
    assert [_one_notif] = Notifications.list_recent(me)
  end

  test "a changed payload parks fresh beside a decided one" do
    me = user()
    {:ok, approval} = park(me)
    {:ok, _} = ImportApprovals.decide(me, approval.id, "dismissed")

    other_hash = String.duplicate("cd", 32)
    assert {:ok, fresh} = park(me, %{"payload_hash" => other_hash, "task_count" => 21})
    assert fresh.status == "pending"
    assert [%{payload_hash: ^other_hash}] = ImportApprovals.list_pending_for_account(me)
  end

  test "decisions are owner-scoped — another user cannot decide your park" do
    me = user()
    {:ok, approval} = park(me)

    assert {:error, :not_pending} = ImportApprovals.decide(user("other"), approval.id, "approved")
    assert ImportApprovals.latest_by_hash(me, @hash).status == "pending"
  end
end
