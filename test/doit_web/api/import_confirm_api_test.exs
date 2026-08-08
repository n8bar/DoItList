defmodule DoItWeb.Api.ImportConfirmApiTest do
  @moduledoc """
  The import-confirm API surface (m03.04 item 30.1): park + read only —
  deciding is deliberately NOT on this surface (the agent holds the
  operator's token; an API decision-write would let it approve its own
  confirm). Covers park idempotency, the bootstrap (account) home, authz on
  Initiative-homed parks, the read by hash, and the decided-row re-park.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, ImportConfirms, Initiatives}

  @hash String.duplicate("cd", 32)

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

  defp token(user) do
    {:ok, {plaintext, _}} = Accounts.mint_api_token(user, "test")
    plaintext
  end

  defp bearer(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp park(conn, tok, body) do
    conn |> bearer(tok) |> post(~p"/api/v1/import_confirms", body)
  end

  setup do
    owner = user("owner")
    viewer = user("viewer")
    stranger = user("stranger")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"}, agent_access: true)

    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    %{owner: owner, viewer: viewer, stranger: stranger, ini: ini}
  end

  test "an Initiative-homed park answers with the pending state and the card's URL", ctx do
    conn =
      park(build_conn(), token(ctx.owner), %{
        "payload_hash" => @hash,
        "readback" => "Importing 40 tasks.",
        "initiative_id" => ctx.ini.id
      })

    assert %{"data" => data} = json_response(conn, 200)
    assert data["status"] == "pending"
    assert data["payload_hash"] == @hash
    assert data["readback"] == "Importing 40 tasks."
    assert data["initiative_id"] == ctx.ini.id
    assert String.ends_with?(data["url"], "/initiatives/#{ctx.ini.id}#import-confirm")
  end

  test "a bootstrap park (no initiative_id) homes on the account", ctx do
    conn =
      park(build_conn(), token(ctx.owner), %{
        "payload_hash" => @hash,
        "readback" => "Bootstrapping a new Initiative with 40 tasks."
      })

    assert %{"data" => data} = json_response(conn, 200)
    assert data["initiative_id"] == nil
    assert String.ends_with?(data["url"], "/account#import-confirms")
    assert [_card] = ImportConfirms.list_pending_for_account(ctx.owner)
  end

  test "park is idempotent: a same home + hash re-park returns the pending row as-is", ctx do
    tok = token(ctx.owner)

    body = %{
      "payload_hash" => @hash,
      "readback" => "Importing 40 tasks.",
      "initiative_id" => ctx.ini.id
    }

    assert %{"data" => first} = json_response(park(build_conn(), tok, body), 200)
    assert %{"data" => second} = json_response(park(build_conn(), tok, body), 200)

    assert second == first
    assert [_only] = ImportConfirms.list_pending_for_initiative(ctx.owner, ctx.ini.id)
  end

  test "a decided row does not block a new park — a fresh pending row opens", ctx do
    tok = token(ctx.owner)

    body = %{
      "payload_hash" => @hash,
      "readback" => "Importing 40 tasks.",
      "initiative_id" => ctx.ini.id
    }

    assert %{"data" => _} = json_response(park(build_conn(), tok, body), 200)
    [confirm] = ImportConfirms.list_pending_for_initiative(ctx.owner, ctx.ini.id)
    {:ok, _} = ImportConfirms.decide(ctx.owner, confirm.id, "held")

    assert %{"data" => reparked} = json_response(park(build_conn(), tok, body), 200)
    assert reparked["status"] == "pending"
    assert [fresh] = ImportConfirms.list_pending_for_initiative(ctx.owner, ctx.ini.id)
    refute fresh.id == confirm.id
  end

  test "Initiative-homed parks are authz-checked", ctx do
    body = %{"payload_hash" => @hash, "readback" => "Importing.", "initiative_id" => ctx.ini.id}

    # A stranger holding a real Initiative id: denied at the role check.
    assert %{"error" => %{"status" => 403}} =
             json_response(park(build_conn(), token(ctx.stranger), body), 403)

    # A viewer can't stage a write either — the confirm guards an apply.
    assert %{"error" => %{"status" => 403}} =
             json_response(park(build_conn(), token(ctx.viewer), body), 403)

    # An unknown id is a 404, same as the read surface.
    unknown = %{body | "initiative_id" => 99_999_999}

    assert %{"error" => %{"status" => 404}} =
             json_response(park(build_conn(), token(ctx.owner), unknown), 404)

    # Agent access off hides the Initiative from the whole /api/v1 surface.
    {:ok, off} = Initiatives.create_initiative(ctx.owner, %{"name" => "Private"})
    hidden = %{body | "initiative_id" => off.id}

    assert %{"error" => %{"status" => 404}} =
             json_response(park(build_conn(), token(ctx.owner), hidden), 404)
  end

  test "a malformed park body is a 422 naming the fields", ctx do
    conn = park(build_conn(), token(ctx.owner), %{"readback" => "no hash"})
    assert %{"error" => %{"status" => 422, "message" => message}} = json_response(conn, 422)
    assert message =~ "payload_hash"
  end

  test "the read answers status, corrections, and url — scoped to the token's user", ctx do
    tok = token(ctx.owner)

    park(build_conn(), tok, %{
      "payload_hash" => @hash,
      "readback" => "Importing 40 tasks.",
      "initiative_id" => ctx.ini.id
    })

    conn = build_conn() |> bearer(tok) |> get(~p"/api/v1/import_confirms/#{@hash}")
    assert %{"data" => %{"status" => "pending", "corrections" => nil}} = json_response(conn, 200)

    [confirm] = ImportConfirms.list_pending_for_initiative(ctx.owner, ctx.ini.id)
    {:ok, _} = ImportConfirms.decide(ctx.owner, confirm.id, "corrected", "Milestones only")

    conn = build_conn() |> bearer(tok) |> get(~p"/api/v1/import_confirms/#{@hash}")
    assert %{"data" => data} = json_response(conn, 200)
    assert data["status"] == "corrected"
    assert data["corrections"] == "Milestones only"
    assert String.ends_with?(data["url"], "/initiatives/#{ctx.ini.id}#import-confirm")

    # Another user's token sees nothing under this hash.
    conn =
      build_conn() |> bearer(token(ctx.stranger)) |> get(~p"/api/v1/import_confirms/#{@hash}")

    assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
  end

  test "an unknown hash reads 404", ctx do
    conn =
      build_conn()
      |> bearer(token(ctx.owner))
      |> get(~p"/api/v1/import_confirms/#{String.duplicate("ef", 32)}")

    assert %{"error" => %{"status" => 404}} = json_response(conn, 404)
  end
end
