defmodule DoItWeb.Client.ClientApiTest do
  @moduledoc """
  The browser client's private data boundary at `/app/api` (m04.01 worklist 5).

  Covers the session endpoint, the two Initiative reads, the operations batch,
  the shared error vocabulary, and — in both directions — the seal between this
  session-authenticated surface and the bearer-token `/api/v1` API.
  """
  use DoItWeb.ConnCase, async: true

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

  defp sign_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  defp token(user) do
    {:ok, {plaintext, _}} = Accounts.mint_api_token(user, "test")
    plaintext
  end

  defp top_task(owner, initiative, title, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        owner,
        Map.merge(
          %{
            "initiative_id" => initiative.id,
            "parent_id" => initiative.root_task_id,
            "title" => title
          },
          attrs
        )
      )

    task
  end

  setup do
    owner = user("owner")
    stranger = user("stranger")

    # Agent access OFF — the default, and the point: the browser surface must
    # still read and write it.
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"})
    {:ok, _} = Initiatives.update_subtitle(ini, "ship the dashboard")
    phase1 = top_task(owner, ini, "Phase 1")

    %{owner: owner, stranger: stranger, ini: ini, phase1: phase1}
  end

  describe "GET /app/api/session" do
    test "returns the signed-in user and a fresh csrf token", %{conn: conn, owner: owner} do
      conn = conn |> sign_in(owner) |> get(~p"/app/api/session")

      assert %{"data" => %{"user" => user, "csrf_token" => csrf}} = json_response(conn, 200)
      assert user["id"] == owner.id
      assert user["email"] == owner.email
      assert user["username"] == owner.username
      assert user["name"] == owner.name
      assert is_binary(csrf) and csrf != ""
    end

    test "signed out is a JSON 401, never an HTML redirect", %{conn: conn} do
      conn = get(conn, ~p"/app/api/session")

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)

      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end
  end

  describe "GET /app/api/initiatives" do
    test "lists an Initiative with agent access OFF, with the index's fields", ctx do
      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives")

      assert %{"data" => [summary]} = json_response(conn, 200)
      assert summary["id"] == ctx.ini.id
      assert summary["name"] == "Q3 Launch"
      assert summary["subtitle"] == "ship the dashboard"
      assert summary["role"] == "owner"
      assert summary["progress"] == 0
      assert summary["unit_count"] == 1
      assert summary["archived"] == false
      # null until the reader drags the list into a manual order.
      assert Map.has_key?(summary, "sort_order")
      assert is_binary(summary["updated_at"])
    end

    test "the bearer API still filters the same Initiative out", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> token(ctx.owner))
        |> get(~p"/api/v1/initiatives")

      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "GET /app/api/initiatives/:id" do
    test "returns the same tree shape the bearer API builds", ctx do
      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{ctx.ini.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == ctx.ini.id
      assert data["role"] == "owner"
      assert data["root_task_id"] == ctx.ini.root_task_id
      assert data["progress_calc"] in ["leaf_average", "single_level"]
      assert [%{"id" => id, "title" => "Phase 1", "children" => []}] = data["tasks"]
      assert id == ctx.phase1.id
    end

    test "a stranger is forbidden and an unknown id is not found", ctx do
      forbidden =
        ctx.conn |> sign_in(ctx.stranger) |> get(~p"/app/api/initiatives/#{ctx.ini.id}")

      assert %{"error" => %{"status" => 403, "code" => "forbidden"}} =
               json_response(forbidden, 403)

      missing = build_conn() |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/98765432")

      assert %{"error" => %{"status" => 404, "code" => "not_found"}} =
               json_response(missing, 404)
    end
  end

  describe "POST /app/api/operations" do
    test "commits a batch against an Initiative with agent access off", ctx do
      conn =
        ctx.conn
        |> sign_in(ctx.owner)
        |> post(~p"/app/api/operations", %{
          "operations" => [
            %{
              "op" => "add",
              "type" => "task",
              "lid" => "t1",
              "data" => %{"parent_id" => ctx.phase1.id, "title" => "Build API"}
            }
          ]
        })

      assert %{"results" => [%{"index" => 0, "lid" => "t1", "status" => "ok", "data" => data}]} =
               json_response(conn, 200)

      assert data["title"] == "Build API"
      assert Tasks.get_task(data["id"]).parent_id == ctx.phase1.id
    end

    test "a validation failure rolls the batch back with per-op results", ctx do
      conn =
        ctx.conn
        |> sign_in(ctx.owner)
        |> post(~p"/app/api/operations", %{
          "operations" => [
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{"parent_id" => ctx.phase1.id, "title" => "Kept?"}
            },
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{"parent_id" => ctx.phase1.id, "title" => ""}
            }
          ]
        })

      assert %{
               "error" => %{"status" => 422, "code" => "unprocessable_entity"},
               "results" => results
             } =
               json_response(conn, 422)

      assert [%{"status" => "not_applied"}, %{"status" => "error"}] = results
      # Nothing landed: Phase 1 is still the only task under the root.
      assert Tasks.subtree_ids(ctx.phase1.id) == [ctx.phase1.id]
    end

    test "an Idempotency-Key replays the stored response instead of re-applying", ctx do
      body = %{
        "operations" => [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t1",
            "data" => %{"parent_id" => ctx.phase1.id, "title" => "Once"}
          }
        ]
      }

      first =
        ctx.conn
        |> sign_in(ctx.owner)
        |> put_req_header("idempotency-key", "browser-key-1")
        |> post(~p"/app/api/operations", body)

      assert %{"results" => [%{"data" => %{"id" => id}}]} = json_response(first, 200)

      second =
        build_conn()
        |> sign_in(ctx.owner)
        |> put_req_header("idempotency-key", "browser-key-1")
        |> post(~p"/app/api/operations", body)

      assert %{"results" => [%{"data" => %{"id" => ^id}}]} = json_response(second, 200)
      assert length(Tasks.subtree_ids(ctx.phase1.id)) == 2
    end

    test "a stranger's write is a 403 through the shared per-op authorize", ctx do
      conn =
        ctx.conn
        |> sign_in(ctx.stranger)
        |> post(~p"/app/api/operations", %{
          "operations" => [
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{"parent_id" => ctx.phase1.id, "title" => "Nope"}
            }
          ]
        })

      assert %{"error" => %{"status" => 403}} = json_response(conn, 403)
    end

    test "an Initiative created from the browser is NOT agent-accessible", ctx do
      conn =
        ctx.conn
        |> sign_in(ctx.owner)
        |> post(~p"/app/api/operations", %{
          "operations" => [
            %{"op" => "add", "type" => "initiative", "data" => %{"name" => "Browser-made"}}
          ]
        })

      assert %{"results" => [%{"data" => %{"id" => id}}]} = json_response(conn, 200)
      refute Initiatives.get_initiative(id).agent_access
    end
  end

  describe "CSRF" do
    test "a write with no csrf token is a JSON 403 stale_session", ctx do
      conn =
        ctx.conn
        |> sign_in(ctx.owner)
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> post(~p"/app/api/operations", %{"operations" => []})

      assert %{"error" => %{"status" => 403, "code" => "stale_session", "message" => message}} =
               json_response(conn, 403)

      assert message =~ "/app/api/session"
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")
    end

    test "the token from GET /app/api/session lets the write through", ctx do
      session_conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/session")
      %{"data" => %{"csrf_token" => csrf}} = json_response(session_conn, 200)

      conn =
        session_conn
        |> recycle()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("x-csrf-token", csrf)
        |> post(~p"/app/api/operations", %{
          "operations" => [
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{"parent_id" => ctx.phase1.id, "title" => "With token"}
            }
          ]
        })

      assert %{"results" => [%{"status" => "ok"}]} = json_response(conn, 200)
    end
  end

  describe "credential separation" do
    test "a valid bearer token alone gets 401 on /app/api", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> token(ctx.owner))
        |> get(~p"/app/api/initiatives")

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)
    end

    test "a signed-in session alone gets 401 on /api/v1", ctx do
      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/api/v1/me")

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)
    end
  end
end
