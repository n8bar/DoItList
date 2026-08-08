defmodule DoIt.ImportConfirmsTest do
  @moduledoc """
  The server-recorded import-confirm context (m03.04 item 30.1): park
  idempotency per home + hash, the record-once decision guard, the
  bootstrap (account) home, and the per-user broadcasts that keep the
  in-app cards live.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, ImportConfirms, Initiatives}

  @hash String.duplicate("ab", 32)

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

  setup do
    owner = user("owner")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"}, agent_access: true)

    %{owner: owner, ini: ini}
  end

  test "park opens a pending row on the Initiative home and broadcasts", ctx do
    :ok = ImportConfirms.subscribe(ctx.owner.id)

    {:ok, confirm} =
      ImportConfirms.park(ctx.owner, ctx.ini.id, %{
        "payload_hash" => @hash,
        "readback" => "Importing 40 tasks."
      })

    assert confirm.status == "pending"
    assert confirm.initiative_id == ctx.ini.id
    assert confirm.user_id == ctx.owner.id
    assert_receive {:import_confirm_parked, %{id: id}}
    assert id == confirm.id
    assert [%{id: ^id}] = ImportConfirms.list_pending_for_initiative(ctx.owner, ctx.ini.id)
  end

  test "park is idempotent per home + hash: the pending row returns as-is", ctx do
    attrs = %{"payload_hash" => @hash, "readback" => "Importing 40 tasks."}
    {:ok, first} = ImportConfirms.park(ctx.owner, ctx.ini.id, attrs)

    :ok = ImportConfirms.subscribe(ctx.owner.id)
    {:ok, second} = ImportConfirms.park(ctx.owner, ctx.ini.id, attrs)

    assert second.id == first.id
    # No duplicate card, no second notification.
    refute_receive {:import_confirm_parked, _}
    assert [_only] = ImportConfirms.list_pending_for_initiative(ctx.owner, ctx.ini.id)
  end

  test "the same hash on a different home is a different confirm", ctx do
    attrs = %{"payload_hash" => @hash, "readback" => "Importing 40 tasks."}
    {:ok, on_initiative} = ImportConfirms.park(ctx.owner, ctx.ini.id, attrs)
    {:ok, on_account} = ImportConfirms.park(ctx.owner, nil, attrs)

    refute on_account.id == on_initiative.id
    assert on_account.initiative_id == nil
    assert [%{id: account_id}] = ImportConfirms.list_pending_for_account(ctx.owner)
    assert account_id == on_account.id
  end

  test "decide records once — a second decision is rejected, not overwritten", ctx do
    {:ok, confirm} =
      ImportConfirms.park(ctx.owner, ctx.ini.id, %{
        "payload_hash" => @hash,
        "readback" => "Importing 40 tasks."
      })

    :ok = ImportConfirms.subscribe(ctx.owner.id)
    assert {:ok, approved} = ImportConfirms.decide(ctx.owner, confirm.id, "approved")
    assert approved.status == "approved"
    assert_receive {:import_confirm_decided, %{status: "approved"}}

    assert {:error, :not_pending} = ImportConfirms.decide(ctx.owner, confirm.id, "held")
    assert ImportConfirms.latest_by_hash(ctx.owner, @hash).status == "approved"
    assert ImportConfirms.list_pending_for_initiative(ctx.owner, ctx.ini.id) == []
  end

  test "corrected requires text; held latches without any", ctx do
    {:ok, confirm} =
      ImportConfirms.park(ctx.owner, ctx.ini.id, %{
        "payload_hash" => @hash,
        "readback" => "Importing 40 tasks."
      })

    assert {:error, :corrections_required} =
             ImportConfirms.decide(ctx.owner, confirm.id, "corrected", "   ")

    assert {:ok, corrected} =
             ImportConfirms.decide(ctx.owner, confirm.id, "corrected", "Milestones only")

    assert corrected.corrections == "Milestones only"

    {:ok, second} =
      ImportConfirms.park(ctx.owner, ctx.ini.id, %{
        "payload_hash" => @hash,
        "readback" => "Importing 40 tasks."
      })

    assert {:ok, held} = ImportConfirms.decide(ctx.owner, second.id, "held")
    assert held.status == "held"
    assert held.corrections == nil
  end

  test "a decided row never blocks a re-park: a fresh pending row opens", ctx do
    attrs = %{"payload_hash" => @hash, "readback" => "Importing 40 tasks."}
    {:ok, first} = ImportConfirms.park(ctx.owner, ctx.ini.id, attrs)
    {:ok, _} = ImportConfirms.decide(ctx.owner, first.id, "held")

    {:ok, second} = ImportConfirms.park(ctx.owner, ctx.ini.id, attrs)

    refute second.id == first.id
    assert second.status == "pending"
    # The consult reads the NEWEST row — the fresh pending one.
    assert ImportConfirms.latest_by_hash(ctx.owner, @hash).id == second.id
  end

  test "another user's confirms are invisible to reads and undecidable", ctx do
    stranger = user("stranger")

    {:ok, confirm} =
      ImportConfirms.park(ctx.owner, nil, %{
        "payload_hash" => @hash,
        "readback" => "Importing 40 tasks."
      })

    assert ImportConfirms.latest_by_hash(stranger, @hash) == nil
    assert ImportConfirms.list_pending_for_account(stranger) == []
    assert {:error, :not_pending} = ImportConfirms.decide(stranger, confirm.id, "approved")
    assert ImportConfirms.latest_by_hash(ctx.owner, @hash).status == "pending"
  end
end
