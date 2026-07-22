defmodule DoItWeb.Api.AgentAccessTest do
  @moduledoc """
  m03.04 item 2.12.2 — the per-Initiative agent-access flag gating the whole
  /api/v1 surface, server-enforced ahead of any work:

    * the list filters to agent-accessible Initiatives only;
    * direct reads (show/activity/members) of a flagged-off Initiative 404 for
      EVERYONE — even its owner — indistinguishable from a nonexistent id;
    * operations writes targeting a flagged-off Initiative fail as not-found,
      masked to the op's own target shape (task/comment targets read as "no
      such task/comment", never confirming they exist), and persist nothing;
    * creation defaults both ways: an API-created Initiative is agent-accessible
      from birth, a UI-created one is not.

  Each test spends at most a few requests per fresh token (the per-token rate
  limit in `config/test.exs` is 5/window).
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}
  alias DoIt.Repo
  alias DoIt.Tasks.Task

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

  defp post_ops(user, operations) do
    conn =
      build_conn()
      |> bearer(token(user))
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  defp top_task(owner, ini, title) do
    {:ok, task} =
      Tasks.create_task(owner, %{
        "initiative_id" => ini.id,
        "parent_id" => ini.root_task_id,
        "title" => title
      })

    task
  end

  setup do
    owner = user("owner")
    {:ok, off} = Initiatives.create_initiative(owner, %{"name" => "Flagged Off"})

    {:ok, on} =
      Initiatives.create_initiative(owner, %{"name" => "Flagged On"}, agent_access: true)

    task = top_task(owner, off, "Hidden Work")
    %{owner: owner, off: off, on: on, task: task}
  end

  describe "GET /api/v1/initiatives (list)" do
    test "excludes flagged-off Initiatives, includes flagged-on", ctx do
      conn = build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives")

      assert %{"data" => list} = json_response(conn, 200)
      ids = Enum.map(list, & &1["id"])
      assert ctx.on.id in ids
      refute ctx.off.id in ids
    end
  end

  describe "direct reads of a flagged-off Initiative" do
    test "show/activity/members 404 for its OWN owner, matching an unknown id", ctx do
      tok = token(ctx.owner)

      show = build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{ctx.off.id}")
      unknown = build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/99999999")

      off_body = json_response(show, 404)
      unknown_body = json_response(unknown, 404)
      # Indistinguishable from not-found: byte-identical bodies.
      assert off_body["error"]["code"] == "not_found"
      assert off_body == unknown_body

      activity =
        build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{ctx.off.id}/activity")

      assert json_response(activity, 404)["error"]["code"] == "not_found"

      members = build_conn() |> bearer(tok) |> get(~p"/api/v1/initiatives/#{ctx.off.id}/members")
      assert json_response(members, 404)["error"]["code"] == "not_found"
    end

    test "the nested comment read 404s too", ctx do
      conn =
        build_conn()
        |> bearer(token(ctx.owner))
        |> get(~p"/api/v1/initiatives/#{ctx.off.id}/tasks/#{ctx.task.id}/comments")

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "operations writes targeting a flagged-off Initiative" do
    test "a task update fails EXACTLY like a nonexistent task and persists nothing", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => ctx.task.id,
            "data" => %{"title" => "smuggled"}
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      # Masked to the target's own shape — the message a truly nonexistent task
      # gets, never naming the Initiative or confirming the task exists.
      assert error["message"] == "No such task with id #{ctx.task.id}."
      assert Repo.get(Task, ctx.task.id).title == "Hidden Work"
    end

    test "an add comment on its task is masked the same way", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "comment",
            "data" => %{"task_id" => ctx.task.id, "body" => "hello?"}
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      assert error["message"] == "No such task with id #{ctx.task.id}."
    end

    test "an edit of an existing comment is masked as no-such-comment", ctx do
      {:ok, comment} = Tasks.add_comment(ctx.task, ctx.owner, "pre-existing")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "comment",
            "id" => comment.id,
            "data" => %{"body" => "edited"}
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      assert error["message"] == "No such comment with id #{comment.id}."
    end

    test "initiative-targeted writes (content update, member add) read as no-such-Initiative",
         ctx do
      other = user("other")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.off.id,
            "data" => %{"name" => "Renamed"}
          },
          %{
            "op" => "add",
            "type" => "member",
            "data" => %{"initiative_id" => ctx.off.id, "user_id" => other.id, "role" => "viewer"}
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      assert error["message"] == "No such Initiative with id #{ctx.off.id}."
      assert Initiatives.get_initiative(ctx.off.id).name == "Flagged Off"
      assert Initiatives.get_role(ctx.off.id, other.id) == nil
    end

    test "an add task into a flagged-off Initiative reads as no-such-Initiative", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{"initiative_id" => ctx.off.id, "title" => "smuggled task"}
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      assert error["message"] == "No such Initiative with id #{ctx.off.id}."
      refute Repo.get_by(Task, title: "smuggled task")
    end

    test "an add task under a parent inside a flagged-off Initiative is masked as no-such-task",
         ctx do
      # Derived path: parent_id resolves the Initiative. A live parent in a
      # flagged-off Initiative must read EXACTLY like a nonexistent parent —
      # never "No such Initiative with id <off>", which confirmed the parent
      # exists and named its Initiative.
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{"parent_id" => ctx.task.id, "title" => "smuggled child"}
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      assert error["message"] == "No such task with id #{ctx.task.id}."
      refute Repo.get_by(Task, title: "smuggled child")
    end

    test "an add naming an accessible Initiative but a parent in a flagged-off one is masked",
         ctx do
      # The parent load masks before parent_in_initiative can name the foreign
      # Initiative ("parent_id P belongs to Initiative B, not A").
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => ctx.on.id,
              "parent_id" => ctx.task.id,
              "title" => "smuggled child"
            }
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      assert error["message"] == "No such task with id #{ctx.task.id}."
      refute Repo.get_by(Task, title: "smuggled child")
    end

    test "an add link whose target is inside a flagged-off Initiative is masked as no-such-task",
         ctx do
      source = top_task(ctx.owner, ctx.on, "Source")

      # Masked before same_initiative_link can say "Task P belongs to Initiative
      # B …" — which confirmed the target and named its Initiative.
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "link",
            "data" => %{"source_id" => source.id, "target_id" => ctx.task.id}
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]
      assert error["code"] == "not_found"
      assert error["message"] == "No such task with id #{ctx.task.id}."
    end

    test "with both Initiatives agent-accessible, the real cross-Initiative guard still fires",
         ctx do
      {:ok, other} =
        Initiatives.create_initiative(ctx.owner, %{"name" => "Other On"}, agent_access: true)

      parent = top_task(ctx.owner, ctx.on, "P")

      # Masking applies only to flagged-off Initiatives — when both are
      # accessible, the genuine parent-mismatch message is unchanged.
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => other.id,
              "parent_id" => parent.id,
              "title" => "x"
            }
          }
        ])

      assert status == 422
      error = Enum.at(body["results"], 0)["error"]

      assert error["message"] ==
               "parent_id #{parent.id} belongs to Initiative #{ctx.on.id}, not Initiative #{other.id}."
    end
  end

  describe "creation defaults" do
    test "an API-created Initiative is agent-accessible from birth and readable at once", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "initiative",
            "lid" => "i1",
            "data" => %{"name" => "Born On"}
          }
        ])

      assert status == 200
      id = Enum.at(body["results"], 0)["data"]["id"]
      assert Initiatives.get_initiative(id).agent_access == true

      conn = build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives/#{id}")
      assert json_response(conn, 200)["data"]["name"] == "Born On"
    end

    test "a UI-created Initiative stays off until the owner opts in", ctx do
      assert Initiatives.get_initiative(ctx.off.id).agent_access == false

      {:ok, _} = Initiatives.set_agent_access(ctx.off, true)

      conn =
        build_conn() |> bearer(token(ctx.owner)) |> get(~p"/api/v1/initiatives/#{ctx.off.id}")

      assert json_response(conn, 200)["data"]["name"] == "Flagged Off"
    end
  end
end
