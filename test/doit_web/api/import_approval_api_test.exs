defmodule DoItWeb.Api.ImportApprovalApiTest do
  @moduledoc """
  The import-approval API surface (m03.04 2.8.8): park + read only — deciding
  is deliberately NOT on this surface (the agent holds the operator's token;
  an API decision-write would let it approve its own import). Covers park
  idempotency, the dismissed latch, the read by hash, and user scoping.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, ImportApprovals}

  @hash String.duplicate("ef", 32)

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
    conn |> bearer(tok) |> post(~p"/api/v1/import_approvals", body)
  end

  @body %{"payload_hash" => @hash, "task_count" => 20, "initiative_name" => "TermiWeb"}

  setup do
    %{owner: user("owner")}
  end

  test "a park answers with the pending state and the account page's URL", ctx do
    conn = park(build_conn(), token(ctx.owner), @body)

    assert %{"data" => data} = json_response(conn, 200)
    assert data["status"] == "pending"
    assert data["payload_hash"] == @hash
    assert data["task_count"] == 20
    assert data["initiative_name"] == "TermiWeb"
    assert String.ends_with?(data["url"], "/account#import-approvals")
    assert [_card] = ImportApprovals.list_pending_for_account(ctx.owner)
  end

  test "park is idempotent: a same-hash re-park returns the pending row as-is", ctx do
    tok = token(ctx.owner)

    assert %{"data" => first} = json_response(park(build_conn(), tok, @body), 200)
    assert %{"data" => second} = json_response(park(build_conn(), tok, @body), 200)

    assert second == first
    assert [_only] = ImportApprovals.list_pending_for_account(ctx.owner)
  end

  test "a dismissed hash stays dismissed through the park — the latch", ctx do
    tok = token(ctx.owner)
    assert %{"data" => _} = json_response(park(build_conn(), tok, @body), 200)

    [approval] = ImportApprovals.list_pending_for_account(ctx.owner)
    {:ok, _} = ImportApprovals.decide(ctx.owner, approval.id, "dismissed")

    assert %{"data" => data} = json_response(park(build_conn(), tok, @body), 200)
    assert data["status"] == "dismissed"
    assert ImportApprovals.list_pending_for_account(ctx.owner) == []
  end

  test "the read by hash answers the newest row's status; unknown hash 404s", ctx do
    tok = token(ctx.owner)
    assert %{"data" => _} = json_response(park(build_conn(), tok, @body), 200)

    conn = build_conn() |> bearer(tok) |> get(~p"/api/v1/import_approvals/#{@hash}")
    assert %{"data" => %{"status" => "pending"}} = json_response(conn, 200)

    conn =
      build_conn()
      |> bearer(tok)
      |> get(~p"/api/v1/import_approvals/#{String.duplicate("00", 32)}")

    assert json_response(conn, 404)
  end

  test "the read is user-scoped — another user's hash is a 404", ctx do
    assert %{"data" => _} = json_response(park(build_conn(), token(ctx.owner), @body), 200)

    conn =
      build_conn()
      |> bearer(token(user("stranger")))
      |> get(~p"/api/v1/import_approvals/#{@hash}")

    assert json_response(conn, 404)
  end

  test "a malformed park body 422s without inserting", ctx do
    conn = park(build_conn(), token(ctx.owner), %{"payload_hash" => @hash})

    assert json_response(conn, 422)
    assert ImportApprovals.list_pending_for_account(ctx.owner) == []
  end

  describe "the account-level off-switch (m03.04 2.8.9)" do
    setup ctx do
      {:ok, owner} = Accounts.set_skip_import_approvals(ctx.owner, true)
      %{owner: owner}
    end

    test "the consult answers skipped for any hash — no row, and over any standing row", ctx do
      tok = token(ctx.owner)

      # No row at all.
      conn = build_conn() |> bearer(tok) |> get(~p"/api/v1/import_approvals/#{@hash}")

      assert %{"data" => %{"status" => "skipped", "payload_hash" => @hash}} =
               json_response(conn, 200)

      # A standing dismissed row doesn't gate a dormant ceremony either: park
      # + dismiss with the ceremony ON, then flip it off and re-consult.
      {:ok, owner} = Accounts.set_skip_import_approvals(ctx.owner, false)
      assert %{"data" => _} = json_response(park(build_conn(), tok, @body), 200)
      [approval] = ImportApprovals.list_pending_for_account(owner)
      {:ok, _} = ImportApprovals.decide(owner, approval.id, "dismissed")
      {:ok, _} = Accounts.set_skip_import_approvals(owner, true)

      conn = build_conn() |> bearer(tok) |> get(~p"/api/v1/import_approvals/#{@hash}")
      assert %{"data" => %{"status" => "skipped"}} = json_response(conn, 200)
    end

    test "the park goes dormant — nothing inserts, no card", ctx do
      conn = park(build_conn(), token(ctx.owner), @body)

      assert %{"data" => %{"status" => "skipped", "payload_hash" => @hash}} =
               json_response(conn, 200)

      assert ImportApprovals.list_pending_for_account(ctx.owner) == []
      assert ImportApprovals.latest_by_hash(ctx.owner, @hash) == nil
    end

    test "the flag is not writable through the operations surface — pinned", ctx do
      # The operator turned the ceremony OFF; prove the agent can't have done
      # it (or undo it) with the token it holds: user self-management is not
      # an op type, and THIS field rides that wall.
      conn =
        build_conn()
        |> bearer(token(ctx.owner))
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/operations", %{
          "operations" => [
            %{
              "op" => "update",
              "type" => "user",
              "id" => ctx.owner.id,
              "data" => %{"skip_import_approvals" => false}
            }
          ]
        })

      body = json_response(conn, 422)
      assert Enum.at(body["results"], 0)["error"]["code"] == "unsupported_op"
      # The stored value never moved.
      assert Accounts.get_user(ctx.owner.id).skip_import_approvals
    end
  end

  test "no decision route exists on the API surface — decisions are app-UI-only" do
    # The router simply has no POST/PATCH on a parked approval's decision;
    # prove the invariant by enumerating the surface.
    routes =
      DoItWeb.Router.__routes__()
      |> Enum.filter(&String.starts_with?(&1.path, "/api/v1/import_approvals"))
      |> Enum.map(&{&1.verb, &1.path})
      |> Enum.sort()

    assert routes == [
             {:get, "/api/v1/import_approvals/:payload_hash"},
             {:post, "/api/v1/import_approvals"}
           ]
  end
end
