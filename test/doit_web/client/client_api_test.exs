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

    test "carries the account's four row-display preferences", %{conn: conn, owner: owner} do
      conn = conn |> sign_in(owner) |> get(~p"/app/api/session")

      # Defaults: every row attribute shown, exactly as the LiveView renders it.
      assert %{"data" => %{"preferences" => prefs}} = json_response(conn, 200)

      assert prefs == %{
               "show_task_priority" => true,
               "show_task_assignee" => true,
               "show_task_progress" => true,
               "show_task_count" => true
             }
    end

    test "row preferences follow what the account saved", %{conn: conn, owner: owner} do
      {:ok, _} =
        DoIt.Accounts.update_preferences(owner, %{
          "show_task_priority" => false,
          "show_task_count" => false
        })

      conn = conn |> sign_in(owner) |> get(~p"/app/api/session")

      assert %{"data" => %{"preferences" => prefs}} = json_response(conn, 200)
      assert prefs["show_task_priority"] == false
      assert prefs["show_task_count"] == false
      assert prefs["show_task_assignee"] == true
      assert prefs["show_task_progress"] == true
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
      # The index card's second line and its Created sort (m04.02 item 4.3).
      assert Map.has_key?(summary, "description")
      assert is_binary(summary["created_at"])
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

  describe "GET /app/api/initiatives/:id/summary" do
    test "a member gets the row the index carries for it", ctx do
      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/summary")
      assert %{"data" => row} = json_response(conn, 200)

      index = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives")
      assert %{"data" => rows} = json_response(index, 200)
      assert row == Enum.find(rows, &(&1["id"] == ctx.ini.id))
      assert row["role"] == "owner"
      assert row["unit_count"] == 1
    end

    test "an Initiative the user archived has no row", ctx do
      _ = Initiatives.archive_initiative(ctx.owner, ctx.ini)

      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/summary")

      assert %{"error" => %{"status" => 404, "code" => "not_found"}} =
               json_response(conn, 404)
    end

    test "a non-member is forbidden and an unknown id is not found", ctx do
      forbidden =
        ctx.conn |> sign_in(ctx.stranger) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/summary")

      assert %{"error" => %{"status" => 403, "code" => "forbidden"}} =
               json_response(forbidden, 403)

      missing =
        build_conn() |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/98765432/summary")

      assert %{"error" => %{"status" => 404, "code" => "not_found"}} =
               json_response(missing, 404)
    end
  end

  describe "GET /app/api/initiatives/:id/members" do
    test "a member sees everyone's role, as the bearer API serialises them", ctx do
      {:ok, _} = Initiatives.add_member(ctx.ini.id, ctx.stranger.id, "viewer")

      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/members")

      assert %{"data" => members} = json_response(conn, 200)
      roles = Map.new(members, &{&1["user_id"], &1["role"]})
      assert roles[ctx.owner.id] == "owner"
      assert roles[ctx.stranger.id] == "viewer"

      owner_row = Enum.find(members, &(&1["user_id"] == ctx.owner.id))
      assert owner_row["name"] == ctx.owner.name
      assert owner_row["username"] == ctx.owner.username
      assert owner_row["email"] == ctx.owner.email
    end

    test "a non-member is forbidden and an unknown id is not found", ctx do
      forbidden =
        ctx.conn |> sign_in(ctx.stranger) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/members")

      assert %{"error" => %{"status" => 403, "code" => "forbidden"}} =
               json_response(forbidden, 403)

      missing =
        build_conn() |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/98765432/members")

      assert %{"error" => %{"status" => 404, "code" => "not_found"}} =
               json_response(missing, 404)
    end

    test "a bearer token alone is a JSON 401", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{token(ctx.owner)}")
        |> get(~p"/app/api/initiatives/#{ctx.ini.id}/members")

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)
    end
  end

  describe "GET /app/api/initiatives/archive" do
    test "lists this user's archived and hidden rows and the owner's Trash", ctx do
      {:ok, old} = Initiatives.create_initiative(ctx.owner, %{"name" => "Old"})
      {:ok, quiet} = Initiatives.create_initiative(ctx.owner, %{"name" => "Quiet"})
      {:ok, gone} = Initiatives.create_initiative(ctx.owner, %{"name" => "Gone"})
      {:ok, _} = Initiatives.archive_initiative(ctx.owner, old)
      {:ok, _} = Initiatives.hide_initiative(ctx.owner, quiet)
      {:ok, _} = Initiatives.trash_initiative(gone)

      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/archive")

      assert %{"data" => %{"archived" => archived, "trashed" => trashed, "retention_days" => 30}} =
               json_response(conn, 200)

      flags = Map.new(archived, &{&1["name"], {&1["archived"], &1["hidden"]}})
      assert flags == %{"Old" => {true, false}, "Quiet" => {false, true}}
      assert Enum.all?(archived, &(&1["role"] == "owner"))

      assert [%{"name" => "Gone", "role" => "owner", "trashed_at" => trashed_at}] = trashed
      assert is_binary(trashed_at)

      # The index still excludes every one of them.
      index = build_conn() |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives")
      names = index |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["name"])
      refute Enum.any?(names, &(&1 in ["Old", "Quiet", "Gone"]))
    end

    test "a member sees their own flags only, and never another owner's Trash", ctx do
      {:ok, _} = Initiatives.add_member(ctx.ini.id, ctx.stranger.id, "viewer")
      {:ok, _} = Initiatives.archive_initiative(ctx.owner, ctx.ini)
      {:ok, gone} = Initiatives.create_initiative(ctx.owner, %{"name" => "Gone"})
      {:ok, _} = Initiatives.trash_initiative(gone)

      conn = ctx.conn |> sign_in(ctx.stranger) |> get(~p"/app/api/initiatives/archive")

      assert %{"data" => %{"archived" => [], "trashed" => []}} = json_response(conn, 200)
    end
  end

  describe "GET /app/api/initiatives/:id/history" do
    test "reports nothing to undo or redo on an untouched stack", ctx do
      {:ok, fresh} = Initiatives.create_initiative(ctx.owner, %{"name" => "Fresh"})

      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{fresh.id}/history")

      assert %{"data" => %{"undo" => nil, "redo" => nil}} = json_response(conn, 200)
    end

    test "labels the next undo, then the redo it leaves behind", ctx do
      {:ok, _} = Tasks.update_task(ctx.phase1, ctx.owner, %{"title" => "Phase one"})

      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/history")

      assert %{"data" => %{"undo" => %{"label" => "Undo rename"}, "redo" => nil}} =
               json_response(conn, 200)

      {:ok, _} = Tasks.undo(ctx.owner, ctx.ini.id)

      after_undo =
        build_conn() |> sign_in(ctx.owner) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/history")

      assert %{"data" => %{"undo" => undo, "redo" => %{"label" => "Redo rename"}}} =
               json_response(after_undo, 200)

      assert is_nil(undo) or is_binary(undo["label"])
    end

    test "a plain viewer has nothing to undo", ctx do
      {:ok, _} = Initiatives.add_member(ctx.ini.id, ctx.stranger.id, "viewer")
      {:ok, _} = Tasks.update_task(ctx.phase1, ctx.owner, %{"title" => "Phase one"})

      conn =
        ctx.conn |> sign_in(ctx.stranger) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/history")

      assert %{"data" => %{"undo" => nil, "redo" => nil}} = json_response(conn, 200)
    end

    test "a non-member is forbidden and a bearer token alone is a 401", ctx do
      forbidden =
        ctx.conn |> sign_in(ctx.stranger) |> get(~p"/app/api/initiatives/#{ctx.ini.id}/history")

      assert %{"error" => %{"status" => 403}} = json_response(forbidden, 403)

      bearer =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token(ctx.owner)}")
        |> get(~p"/app/api/initiatives/#{ctx.ini.id}/history")

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(bearer, 401)
    end
  end

  describe "GET /app/api/notifications" do
    test "returns the user's recent notifications, serialised, with the unread count", ctx do
      {:ok, _} =
        DoIt.Notifications.create(ctx.owner.id, "assigned", %{
          "actor_name" => "Dana",
          "task_title" => "Ship it",
          "initiative_id" => ctx.ini.id,
          "task_id" => ctx.phase1.id
        })

      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/notifications")

      assert %{"data" => %{"recent" => [row], "unread" => 1}} = json_response(conn, 200)
      assert row["kind"] == "assigned"
      assert row["line"] == "Dana assigned you \u201cShip it\u201d"
      assert row["href"] == "/app/initiatives/#{ctx.ini.id}?task=#{ctx.phase1.id}"
      assert row["read"] == false
      assert is_binary(row["inserted_at"])
    end

    test "never carries another user's notifications", ctx do
      {:ok, _} = DoIt.Notifications.create(ctx.stranger.id, "member_added", %{})

      conn = ctx.conn |> sign_in(ctx.owner) |> get(~p"/app/api/notifications")

      assert %{"data" => %{"recent" => [], "unread" => 0}} = json_response(conn, 200)
    end

    test "a bearer token alone is a JSON 401 — the bell is browser-private", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer #{token(ctx.owner)}")
        |> get(~p"/app/api/notifications")

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)
    end

    test "signed out is a JSON 401", %{conn: conn} do
      assert %{"error" => %{"code" => "unauthorized"}} =
               conn |> get(~p"/app/api/notifications") |> json_response(401)
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

    test "a bearer token alone cannot WRITE on /app/api either", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> token(ctx.owner))
        |> post(~p"/app/api/operations", %{
          "operations" => [
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{"parent_id" => ctx.phase1.id, "title" => "Bearer write"}
            }
          ]
        })

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)
    end

    test "a bearer token alone cannot read the client's session endpoint", ctx do
      conn =
        ctx.conn
        |> put_req_header("authorization", "Bearer " <> token(ctx.owner))
        |> get(~p"/app/api/session")

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)
    end

    test "a signed-in session alone cannot WRITE on /api/v1 either", ctx do
      conn =
        ctx.conn
        |> sign_in(ctx.owner)
        |> post(~p"/api/v1/operations", %{
          "operations" => [
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{"parent_id" => ctx.phase1.id, "title" => "Session write"}
            }
          ]
        })

      assert %{"error" => %{"status" => 401, "code" => "unauthorized"}} =
               json_response(conn, 401)
    end

    test "a bearer token beside a session never raises the session's authority", ctx do
      # The stranger's token on a conn signed in as the owner: /app/api must
      # answer as the SESSION's user, and must not adopt the token at all.
      conn =
        ctx.conn
        |> sign_in(ctx.owner)
        |> put_req_header("authorization", "Bearer " <> token(ctx.stranger))
        |> get(~p"/app/api/session")

      assert %{"data" => %{"user" => %{"id" => id}}} = json_response(conn, 200)
      assert id == ctx.owner.id
    end
  end
end
