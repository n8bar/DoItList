defmodule DoItWeb.Api.OperationsTest do
  @moduledoc """
  The atomic mutation surface — `POST /api/v1/operations` (m03.01 worklist 3).

  Covers: an ordered multi-op batch applied all-or-nothing; `lid` local-id
  resolution (create parent → child via lid); a bad op mid-batch rolling
  EVERYTHING back with the offending index; the per-op error shapes (validation,
  not-found, bad-lid, authz); an unauthorized op (viewer write / editor admin-op)
  failing the batch with 403 and persisting nothing; irreversible ops rejected;
  a single-op batch.

  Persistence is checked through the domain contexts (not extra API reads) so the
  per-token rate limit (5/window in `config/test.exs`) never bites — each test's
  fresh token spends one POST.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Notifications, Tasks}
  alias DoIt.Repo
  alias DoIt.Tasks.{Comment, Task}
  alias DoItWeb.Api.Operations

  # DoIt.Broadcast's per-process queue key (it stays in the process dictionary
  # until flushed/discarded). Read directly to assert the queue-drop guarantee.
  @pending :doit_pending_broadcasts

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

  # POST a batch as `user` and return the decoded body + status.
  defp post_ops(user, operations) do
    conn =
      build_conn()
      |> bearer(token(user))
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/operations", %{"operations" => operations})

    {conn.status, json_response(conn, conn.status)}
  end

  defp top_task(owner, ini, title, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        owner,
        Map.merge(
          %{"initiative_id" => ini.id, "parent_id" => ini.root_task_id, "title" => title},
          attrs
        )
      )

    task
  end

  setup do
    owner = user("owner")
    editor = user("editor")
    viewer = user("viewer")
    stranger = user("stranger")

    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Q3 Launch"})
    {:ok, _} = Initiatives.add_member(ini.id, editor.id, "editor")
    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    %{owner: owner, editor: editor, viewer: viewer, stranger: stranger, ini: ini}
  end

  describe "single-op batch" do
    test "a batch of one creates a task and echoes the new id", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t1",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Solo"
            }
          }
        ])

      assert status == 200
      assert [%{"index" => 0, "lid" => "t1", "status" => "ok", "data" => data}] = body["results"]
      assert data["type"] == "task"
      assert is_integer(data["id"])
      assert data["title"] == "Solo"

      # Persisted under the root.
      assert %Task{title: "Solo"} = Repo.get(Task, data["id"])
    end
  end

  describe "one-batch bootstrap: Initiative + its first top-level task" do
    test "an add task with initiative_lid and no parent lands under the new root", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{"op" => "add", "type" => "initiative", "lid" => "i1", "data" => %{"name" => "Fresh"}},
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t1",
            # initiative_lid points at the same-batch Initiative; NO parent given,
            # so it must default to that Initiative's root task.
            "data" => %{"initiative_lid" => "i1", "title" => "First task"}
          }
        ])

      assert status == 200

      assert [
               %{"index" => 0, "lid" => "i1", "status" => "ok", "data" => ini_data},
               %{"index" => 1, "lid" => "t1", "status" => "ok", "data" => task_data}
             ] = body["results"]

      assert ini_data["type"] == "initiative"
      assert task_data["type"] == "task"
      assert task_data["title"] == "First task"

      # The task is a child of the brand-new Initiative's root task.
      root_id = ini_data["root_task_id"]
      assert is_integer(root_id)
      assert task_data["parent_id"] == root_id

      # And it persisted under that root, in that Initiative.
      assert %Task{parent_id: ^root_id, initiative_id: ini_id} = Repo.get(Task, task_data["id"])
      assert ini_id == ini_data["id"]
    end
  end

  describe "ordered multi-op batch (all-or-nothing happy path)" do
    test "applies every op and all persist", ctx do
      phase1 = top_task(ctx.owner, ctx.ini, "Phase 1")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "a",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => phase1.id,
              "title" => "Build"
            }
          },
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "b",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => phase1.id,
              "title" => "Docs"
            }
          },
          %{
            "op" => "update",
            "type" => "task",
            "lid" => "a",
            "data" => %{"manual_progress" => 50}
          },
          %{
            "op" => "update",
            "type" => "task",
            "lid" => "b",
            "data" => %{"manual_progress" => 100}
          }
        ])

      assert status == 200
      assert Enum.all?(body["results"], &(&1["status"] == "ok"))

      [a, b | _] = body["results"]
      task_a = Repo.get(Task, a["data"]["id"])
      task_b = Repo.get(Task, b["data"]["id"])
      assert task_a.manual_progress == 50
      assert task_b.manual_progress == 100

      # Branch rolled up to the average (50 + 100) / 2 = 75.
      assert Repo.get(Task, phase1.id).computed_progress == 75
    end
  end

  describe "lid local-id resolution" do
    test "create parent (lid) then child referencing parent_lid — child lands under the new parent",
         ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "p",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Parent"
            }
          },
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "c",
            "data" => %{"parent_lid" => "p", "title" => "Child"}
          }
        ])

      assert status == 200
      [parent_res, child_res] = body["results"]
      parent_id = parent_res["data"]["id"]
      child = Repo.get(Task, child_res["data"]["id"])

      assert child.parent_id == parent_id
      # initiative_id was derived from the resolved parent.
      assert child.initiative_id == ctx.ini.id
    end

    test "an unknown / forward lid is a per-op bad_reference and rolls back", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "c",
            "data" => %{"parent_lid" => "does-not-exist", "title" => "Orphan"}
          }
        ])

      assert status == 422

      assert [%{"index" => 0, "status" => "error", "error" => %{"code" => "bad_reference"}}] =
               body["results"]

      refute Repo.get_by(Task, title: "Orphan")
    end

    test "a duplicate lid is rejected", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "dup",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "First"
            }
          },
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "dup",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Second"
            }
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 1)["error"]["code"] == "bad_reference"
      refute Repo.get_by(Task, title: "First")
    end
  end

  describe "all-or-nothing rollback on a bad op mid-batch" do
    test "a validation failure mid-batch leaves NOTHING persisted and flags the offending index",
         ctx do
      phase1 = top_task(ctx.owner, ctx.ini, "Phase 1")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "a",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => phase1.id,
              "title" => "Good One"
            }
          },
          # Blank title → changeset validation error.
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "b",
            "data" => %{"initiative_id" => ctx.ini.id, "parent_id" => phase1.id, "title" => ""}
          },
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "c",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => phase1.id,
              "title" => "Never Runs"
            }
          }
        ])

      assert status == 422
      assert body["error"]["status"] == 422

      results = body["results"]
      assert Enum.at(results, 0)["status"] == "not_applied"
      assert Enum.at(results, 1)["status"] == "error"
      assert Enum.at(results, 1)["index"] == 1
      assert Enum.at(results, 1)["error"]["code"] == "unprocessable_entity"
      assert Enum.at(results, 1)["error"]["pointer"] == "title"
      assert Enum.at(results, 2)["status"] == "not_applied"

      # The earlier successful op was rolled back: only Phase 1 lives under root.
      refute Repo.get_by(Task, title: "Good One")
      refute Repo.get_by(Task, title: "Never Runs")
    end

    test "a not-found target mid-batch rolls back the whole batch", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "a",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Will Vanish"
            }
          },
          %{
            "op" => "update",
            "type" => "task",
            "id" => 99_999_999,
            "data" => %{"title" => "ghost"}
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 1)["error"]["code"] == "not_found"
      refute Repo.get_by(Task, title: "Will Vanish")
    end
  end

  describe "authorization (no privilege escalation)" do
    test "a viewer write fails the batch with 403 and persists nothing", ctx do
      {status, body} =
        post_ops(ctx.viewer, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Viewer Tried"
            }
          }
        ])

      assert status == 403
      assert body["error"]["status"] == 403
      assert Enum.at(body["results"], 0)["error"]["code"] == "forbidden"
      refute Repo.get_by(Task, title: "Viewer Tried")
    end

    test "an editor attempting an admin-only member op fails with 403; the whole batch rolls back",
         ctx do
      target = user("newbie")

      {status, body} =
        post_ops(ctx.editor, [
          # A legal editor write first…
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Editor Task"
            }
          },
          # …then an admin-only membership add the editor can't do.
          %{
            "op" => "add",
            "type" => "member",
            "data" => %{"initiative_id" => ctx.ini.id, "user_id" => target.id, "role" => "viewer"}
          }
        ])

      assert status == 403
      assert Enum.at(body["results"], 1)["error"]["code"] == "forbidden"
      # The earlier task was rolled back, and no membership was created.
      refute Repo.get_by(Task, title: "Editor Task")
      assert Initiatives.get_role(ctx.ini.id, target.id) == nil
    end

    test "a stranger (non-member) write is forbidden", ctx do
      {status, _body} =
        post_ops(ctx.stranger, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Nope"
            }
          }
        ])

      assert status == 403
      refute Repo.get_by(Task, title: "Nope")
    end
  end

  describe "the wired op set (representative coverage)" do
    test "task: update fields, set progress, complete (done), reorder, reparent, soft-delete",
         ctx do
      a = top_task(ctx.owner, ctx.ini, "A")
      b = top_task(ctx.owner, ctx.ini, "B")

      {status, _body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => a.id,
            "data" => %{
              "title" => "A renamed",
              "priority" => "high",
              "assignee_id" => ctx.editor.id
            }
          },
          %{
            "op" => "update",
            "type" => "task",
            "id" => b.id,
            "data" => %{"manual_progress" => 40}
          },
          %{"op" => "update", "type" => "task", "id" => b.id, "data" => %{"done" => true}},
          %{
            "op" => "update",
            "type" => "task",
            "id" => a.id,
            "data" => %{"position" => 0, "reorder" => true}
          }
        ])

      assert status == 200
      updated_a = Repo.get(Task, a.id)
      assert updated_a.title == "A renamed"
      assert updated_a.priority == "high"
      assert updated_a.assignee_id == ctx.editor.id
      assert Repo.get(Task, b.id).status == "done"
    end

    test "task: reparent via parent_lid + soft-delete are reversible ops", ctx do
      existing = top_task(ctx.owner, ctx.ini, "Existing")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "p",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "New Parent"
            }
          },
          %{
            "op" => "update",
            "type" => "task",
            "id" => existing.id,
            "data" => %{"parent_lid" => "p"}
          }
        ])

      assert status == 200
      new_parent_id = Enum.at(body["results"], 0)["data"]["id"]
      assert Repo.get(Task, existing.id).parent_id == new_parent_id

      # Soft-delete keeps the row (deleted_at stamped), not a hard delete.
      {del_status, _} =
        post_ops(ctx.owner, [%{"op" => "remove", "type" => "task", "id" => existing.id}])

      assert del_status == 200
      assert Repo.get(Task, existing.id).deleted_at != nil
    end

    test "initiative: reversible trash + restore lifecycle (admin-gated)", ctx do
      {trash_status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"state" => "trashed"}
          }
        ])

      assert trash_status == 200
      assert Repo.get(DoIt.Initiatives.Initiative, ctx.ini.id).trashed_at != nil

      {restore_status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"state" => "restored"}
          }
        ])

      assert restore_status == 200
      assert Repo.get(DoIt.Initiatives.Initiative, ctx.ini.id).trashed_at == nil
    end

    test "initiative: trash is admin-gated — an editor is refused", ctx do
      {status, body} =
        post_ops(ctx.editor, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"state" => "trashed"}
          }
        ])

      assert status == 403
      assert Enum.at(body["results"], 0)["error"]["code"] == "forbidden"
      assert Repo.get(DoIt.Initiatives.Initiative, ctx.ini.id).trashed_at == nil
    end

    test "initiative: create then add a task into it via initiative_lid + root resolution", ctx do
      # Create an Initiative and a top-level task under its root in one batch.
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "initiative",
            "lid" => "i1",
            "data" => %{"name" => "Fresh Initiative"}
          },
          %{
            "op" => "update",
            "type" => "initiative",
            "lid" => "i1",
            "data" => %{"subtitle" => "renamed subtitle", "index_style" => "roman"}
          }
        ])

      assert status == 200
      ini_id = Enum.at(body["results"], 0)["data"]["id"]
      reloaded = Repo.get(DoIt.Initiatives.Initiative, ini_id)
      assert reloaded.name == "Fresh Initiative"
      assert reloaded.index_style == "roman"
      assert Initiatives.subtitle(reloaded) == "renamed subtitle"
      # Creator is the owner.
      assert Initiatives.get_role(ini_id, ctx.owner.id) == "owner"
    end

    test "task: set the full co-assignee list", ctx do
      task = top_task(ctx.owner, ctx.ini, "Shared")

      {status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => task.id,
            "data" => %{"co_assignee_ids" => [ctx.editor.id, ctx.viewer.id]}
          }
        ])

      assert status == 200
      co_ids = task.id |> Tasks.list_co_assignees() |> Enum.map(& &1.user_id)
      assert co_ids == [ctx.editor.id, ctx.viewer.id]
    end

    test "initiative: per-user archive then unarchive (view-gated, own membership)", ctx do
      {status, _} =
        post_ops(ctx.viewer, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"state" => "archived"}
          }
        ])

      assert status == 200
      assert Enum.any?(Initiatives.list_archived_initiatives(ctx.viewer), &(&1.id == ctx.ini.id))
    end

    test "comment: add, edit, soft-delete-with-tombstone", ctx do
      task = top_task(ctx.owner, ctx.ini, "Commented Task")

      {add_status, add_body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "comment",
            "lid" => "c1",
            "data" => %{"task_id" => task.id, "body" => "first"}
          }
        ])

      assert add_status == 200
      comment_id = Enum.at(add_body["results"], 0)["data"]["id"]
      assert %Comment{body: "first"} = Repo.get(Comment, comment_id)

      {edit_status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "comment",
            "id" => comment_id,
            "data" => %{"body" => "edited"}
          }
        ])

      assert edit_status == 200
      assert Repo.get(Comment, comment_id).body == "edited"

      {del_status, _} =
        post_ops(ctx.owner, [%{"op" => "remove", "type" => "comment", "id" => comment_id}])

      assert del_status == 200
      tombstone = Repo.get(Comment, comment_id)
      # Tombstone: row survives, deleted markers set.
      assert tombstone.deleted_by_id == ctx.owner.id
      assert Tasks.comment_deleted?(tombstone)
    end

    test "comment: a non-author edit is forbidden (author-only enforced by the context)", ctx do
      task = top_task(ctx.owner, ctx.ini, "Owner Task")
      {:ok, comment} = Tasks.add_comment(task, ctx.owner, "owner's comment")

      {status, body} =
        post_ops(ctx.editor, [
          %{
            "op" => "update",
            "type" => "comment",
            "id" => comment.id,
            "data" => %{"body" => "hijack"}
          }
        ])

      assert status == 403
      assert Enum.at(body["results"], 0)["error"]["code"] == "forbidden"
      assert Repo.get(Comment, comment.id).body == "owner's comment"
    end

    test "member: add, role-change, remove (admin-gated)", ctx do
      target = user("member")

      {add_status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "member",
            "data" => %{"initiative_id" => ctx.ini.id, "user_id" => target.id, "role" => "viewer"}
          }
        ])

      assert add_status == 200
      assert Initiatives.get_role(ctx.ini.id, target.id) == "viewer"

      {role_status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "member",
            "data" => %{"initiative_id" => ctx.ini.id, "user_id" => target.id, "role" => "editor"}
          }
        ])

      assert role_status == 200
      assert Initiatives.get_role(ctx.ini.id, target.id) == "editor"

      {rm_status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "remove",
            "type" => "member",
            "data" => %{"initiative_id" => ctx.ini.id, "user_id" => target.id}
          }
        ])

      assert rm_status == 200
      assert Initiatives.get_role(ctx.ini.id, target.id) == nil
    end

    test "notification: mark one read (own) and mark all read", ctx do
      # Generate a notification for the editor by changing their role (owner acts).
      {:ok, _} = Initiatives.update_member_role(ctx.ini.id, ctx.editor.id, "viewer", ctx.owner)
      [notif | _] = Notifications.list_recent(ctx.editor)
      assert is_nil(notif.read_at)

      {status, _} =
        post_ops(ctx.editor, [
          %{
            "op" => "update",
            "type" => "notification",
            "id" => notif.id,
            "data" => %{"read" => true}
          }
        ])

      assert status == 200
      assert Notifications.get(notif.id).read_at != nil
    end

    test "notification: mark all read clears the acting user's unread feed", ctx do
      {:ok, _} = Initiatives.update_member_role(ctx.ini.id, ctx.editor.id, "viewer", ctx.owner)
      assert Notifications.unread_count(ctx.editor) > 0

      {status, _} =
        post_ops(ctx.editor, [
          %{"op" => "update", "type" => "notification", "data" => %{"all" => true}}
        ])

      assert status == 200
      assert Notifications.unread_count(ctx.editor) == 0
    end

    test "notification: marking another user's notification is forbidden", ctx do
      {:ok, _} = Initiatives.update_member_role(ctx.ini.id, ctx.editor.id, "viewer", ctx.owner)
      [notif | _] = Notifications.list_recent(ctx.editor)

      {status, body} =
        post_ops(ctx.viewer, [
          %{
            "op" => "update",
            "type" => "notification",
            "id" => notif.id,
            "data" => %{"read" => true}
          }
        ])

      assert status == 403
      assert Enum.at(body["results"], 0)["error"]["code"] == "forbidden"
      assert is_nil(Notifications.get(notif.id).read_at)
    end
  end

  describe "irreversible ops are rejected" do
    test "remove initiative (permanent delete) → irreversible_op, Initiative survives", ctx do
      {status, body} =
        post_ops(ctx.owner, [%{"op" => "remove", "type" => "initiative", "id" => ctx.ini.id}])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "irreversible_op"
      assert Repo.get(DoIt.Initiatives.Initiative, ctx.ini.id) != nil
    end

    test "transferring ownership via update initiative {owner_id} → irreversible_op", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"owner_id" => ctx.editor.id}
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "irreversible_op"
      # Ownership unchanged.
      assert Repo.get(DoIt.Initiatives.Initiative, ctx.ini.id).owner_id == ctx.owner.id
    end

    test "an unsupported type (account/user self-management) → unsupported_op", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "user",
            "id" => ctx.owner.id,
            "data" => %{"name" => "Hacked"}
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "unsupported_op"
    end

    test "add member with role owner → irreversible_op, no owner minted", ctx do
      target = user("newbie")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "member",
            "data" => %{"initiative_id" => ctx.ini.id, "user_id" => target.id, "role" => "owner"}
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "irreversible_op"
      assert Enum.at(body["results"], 0)["error"]["pointer"] == "role"
      # No member row created at all (the op failed before any write).
      assert is_nil(Initiatives.get_role(ctx.ini.id, target.id))
    end

    test "update member to role owner → irreversible_op, role + sole-owner unchanged", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "member",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "user_id" => ctx.editor.id,
              "role" => "owner"
            }
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "irreversible_op"
      # The editor stays an editor; ctx.owner remains the sole owner_id.
      assert Initiatives.get_role(ctx.ini.id, ctx.editor.id) == "editor"
      assert Repo.get(DoIt.Initiatives.Initiative, ctx.ini.id).owner_id == ctx.owner.id
    end
  end

  describe "malformed requests" do
    test "a missing/empty operations array is a 422 single-error", ctx do
      conn =
        build_conn()
        |> bearer(token(ctx.owner))
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/operations", %{"operations" => []})

      assert %{"error" => %{"status" => 422}} = json_response(conn, 422)
    end

    test "a request with no token is a 401", _ctx do
      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/operations", %{"operations" => []})

      assert json_response(conn, 401)["error"]["code"] == "unauthorized"
    end

    test "a non-map \"data\" (string) is a clean per-op error, not a 500", ctx do
      # The add-initiative path reaches data/1 before any authorization, so this
      # is the cheapest trigger; a string would raise on Map.* without the guard.
      {status, body} =
        post_ops(ctx.owner, [%{"op" => "add", "type" => "initiative", "data" => "haha"}])

      assert status == 422
      assert Enum.at(body["results"], 0)["status"] == "error"
      assert Enum.at(body["results"], 0)["error"]["code"] == "unprocessable_entity"
      assert Enum.at(body["results"], 0)["error"]["pointer"] == "data"
    end

    test "a non-map \"data\" (array) is a clean per-op error, not a 500", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => [1, 2, 3]
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "unprocessable_entity"
      assert Enum.at(body["results"], 0)["error"]["pointer"] == "data"
    end
  end

  describe "unrecognized data keys are rejected with a targeted per-op error" do
    test "update task with the derived `progress` key is a 422 pointing at manual_progress",
         ctx do
      task = top_task(ctx.owner, ctx.ini, "Has progress")

      {status, body} =
        post_ops(ctx.owner, [
          %{"op" => "update", "type" => "task", "id" => task.id, "data" => %{"progress" => 50}}
        ])

      assert status == 422
      err = Enum.at(body["results"], 0)["error"]
      assert err["code"] == "unprocessable_entity"
      assert err["pointer"] == "progress"
      # The accepted-keys list surfaces the writable field the caller meant.
      assert err["message"] =~ "Accepted data keys:"
      assert err["message"] =~ "manual_progress"
    end

    test "add task with an unknown data key is a 422 listing the accepted keys", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Colourful",
              "colour" => "red"
            }
          }
        ])

      assert status == 422
      err = Enum.at(body["results"], 0)["error"]
      assert err["code"] == "unprocessable_entity"
      assert err["pointer"] == "colour"
      assert err["message"] =~ "Accepted data keys:"
      assert err["message"] =~ "title"
      # Failed before any write — the otherwise-valid task did not persist.
      assert is_nil(Repo.get_by(Task, title: "Colourful"))
    end

    test "add member with an unknown data key is a targeted 422, nothing written", ctx do
      target = user("newbie")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "member",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "user_id" => target.id,
              "role" => "viewer",
              "nickname" => "buddy"
            }
          }
        ])

      assert status == 422
      err = Enum.at(body["results"], 0)["error"]
      assert err["code"] == "unprocessable_entity"
      assert err["pointer"] == "nickname"
      assert is_nil(Initiatives.get_role(ctx.ini.id, target.id))
    end

    test "update initiative with an unknown content key is a targeted 422 (unified message)",
         ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "initiative",
            "id" => ctx.ini.id,
            "data" => %{"colour" => "red"}
          }
        ])

      assert status == 422
      err = Enum.at(body["results"], 0)["error"]
      assert err["code"] == "unprocessable_entity"
      assert err["pointer"] == "colour"
      assert err["message"] =~ "isn't accepted"
      assert err["message"] =~ "Accepted data keys:"
    end

    test "a valid update task with manual_progress still succeeds (no false positive)", ctx do
      task = top_task(ctx.owner, ctx.ini, "Leaf")

      {status, _body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => task.id,
            "data" => %{"manual_progress" => 50}
          }
        ])

      assert status == 200
      assert Repo.get(Task, task.id).manual_progress == 50
    end
  end

  describe "cross-initiative integrity (per-op authorization)" do
    test "add task with a foreign parent_id is rejected and mutates nothing", ctx do
      # Attacker is owner of their OWN Initiative but has no role on ctx.ini.
      attacker = user("attacker")
      {:ok, attacker_ini} = Initiatives.create_initiative(attacker, %{"name" => "Attacker Land"})

      # A DONE task in the victim Initiative — the exploit would flip it open via
      # reconcile_after_create's unscoped ancestor walk.
      victim_parent = top_task(ctx.owner, ctx.ini, "Victim Parent")
      {:ok, victim_parent} = Tasks.cascade_complete(victim_parent, ctx.owner)
      assert victim_parent.status == "done"

      {status, body} =
        post_ops(attacker, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => attacker_ini.id,
              "parent_id" => victim_parent.id,
              "title" => "Injected"
            }
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "unprocessable_entity"
      assert Enum.at(body["results"], 0)["error"]["pointer"] == "parent_id"

      # The victim's done task was NOT flipped, and no child straddling the two
      # Initiatives was injected.
      assert Repo.get(Task, victim_parent.id).status == "done"
      assert is_nil(Repo.get_by(Task, title: "Injected"))
    end
  end

  describe "transactional PubSub side effects (no broadcast escapes a rolled-back batch)" do
    test "a member op's broadcast is dropped when a later op rolls the batch back", ctx do
      target = user("joiner")
      Phoenix.PubSub.subscribe(DoIt.PubSub, "initiative:#{ctx.ini.id}")

      {status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "member",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "user_id" => target.id,
              "role" => "viewer"
            }
          },
          # Blank title → validation failure → the whole batch rolls back.
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => ""
            }
          }
        ])

      assert status == 422
      # The member row reverted AND its {:members_changed} broadcast never left.
      assert is_nil(Initiatives.get_role(ctx.ini.id, target.id))
      refute_receive {:members_changed, _}
    end

    test "a committed member op's broadcast fires (post-commit)", ctx do
      target = user("joiner")
      Phoenix.PubSub.subscribe(DoIt.PubSub, "initiative:#{ctx.ini.id}")

      {status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "member",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "user_id" => target.id,
              "role" => "viewer"
            }
          }
        ])

      assert status == 200
      assert_receive {:members_changed, _}
    end
  end

  describe "membership parity — assignee / co-assignee must be a member (Defect A)" do
    test "add task assigning a non-member is rejected, persists nothing, notifies no one", ctx do
      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Leak",
              "assignee_id" => ctx.stranger.id
            }
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["code"] == "unprocessable_entity"
      assert Enum.at(body["results"], 0)["error"]["pointer"] == "assignee_id"

      # Nothing persisted and the stranger's feed was never touched.
      assert is_nil(Repo.get_by(Task, title: "Leak"))
      assert Notifications.list_recent(ctx.stranger) == []
    end

    test "updating a task's assignee to a non-member is rejected; assignee unchanged, no notification",
         ctx do
      task = top_task(ctx.owner, ctx.ini, "Has no assignee")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => task.id,
            "data" => %{"assignee_id" => ctx.stranger.id}
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["pointer"] == "assignee_id"

      assert is_nil(Repo.get(Task, task.id).assignee_id)
      assert Notifications.list_recent(ctx.stranger) == []
    end

    test "co-assigning a non-member is rejected; no link persists (whole batch rolls back), no notification",
         ctx do
      task = top_task(ctx.owner, ctx.ini, "Shared")

      {status, body} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => task.id,
            # editor is a real member, stranger is not — one stranger rejects the op.
            "data" => %{"co_assignee_ids" => [ctx.editor.id, ctx.stranger.id]}
          }
        ])

      assert status == 422
      assert Enum.at(body["results"], 0)["error"]["pointer"] == "co_assignee_ids"

      # Even the valid co-assignee (editor) was not written — all-or-nothing.
      assert Tasks.list_co_assignees(task.id) == []
      assert Notifications.list_recent(ctx.stranger) == []
    end

    test "assigning a real member still works", ctx do
      task = top_task(ctx.owner, ctx.ini, "Real assign")

      {status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => task.id,
            "data" => %{"assignee_id" => ctx.editor.id}
          }
        ])

      assert status == 200
      assert Repo.get(Task, task.id).assignee_id == ctx.editor.id
    end

    test "co-assigning real members still works", ctx do
      task = top_task(ctx.owner, ctx.ini, "Real co")

      {status, _} =
        post_ops(ctx.owner, [
          %{
            "op" => "update",
            "type" => "task",
            "id" => task.id,
            "data" => %{"co_assignee_ids" => [ctx.editor.id, ctx.viewer.id]}
          }
        ])

      assert status == 200
      co_ids = task.id |> Tasks.list_co_assignees() |> Enum.map(& &1.user_id)
      assert co_ids == [ctx.editor.id, ctx.viewer.id]
    end
  end

  describe "broadcast queue is dropped on the raise path (Defect B — no cross-request leak)" do
    # The queue lives in the process dictionary; Bandit reuses one connection
    # process across keep-alive requests, so a queue that survives a raised
    # request would be flushed by the NEXT successful one (phantom broadcasts
    # for never-persisted rows). apply_batch must leave the queue empty on every
    # exit. Driven directly (not over HTTP): under the SQL sandbox
    # Repo.in_transaction? is always true so flush/1 is a no-op, so we assert the
    # drop on the process queue itself.
    test "an op that RAISES inside the transaction leaves no queued broadcasts behind", ctx do
      joiner = user("joiner")
      task = top_task(ctx.owner, ctx.ini, "Target")
      # A bigint-overflowing assignee id forces a real raise (DBConnection encode
      # error) deep inside the transaction — exactly the re-raising path that
      # used to skip flush/1.
      overflow_id = 9_999_999_999_999_999_999_999

      batch = [
        # Op 1 succeeds and QUEUES broadcasts (members_changed + notification).
        %{
          "op" => "add",
          "type" => "member",
          "data" => %{"initiative_id" => ctx.ini.id, "user_id" => joiner.id, "role" => "viewer"}
        },
        # Op 2 raises, rolling the batch (and op 1's queued broadcasts) back.
        %{
          "op" => "update",
          "type" => "task",
          "id" => task.id,
          "data" => %{"assignee_id" => overflow_id}
        }
      ]

      assert Process.get(@pending, []) == []

      raised? =
        try do
          Operations.apply_batch(ctx.owner, batch)
          false
        rescue
          _ -> true
        end

      assert raised?, "expected the overflowing assignee to raise inside the transaction"
      # The rolled-back batch's queued broadcasts did NOT linger on the process.
      assert Process.get(@pending, []) == []
    end

    test "a fresh apply_batch drops broadcast residue left by a prior raised request", ctx do
      # Simulate residue a prior raised request left queued on this process.
      Process.put(@pending, [{"phantom:topic", {:notification, %{phantom: true}}}])

      {:ok, _results} =
        Operations.apply_batch(ctx.owner, [
          %{
            "op" => "add",
            "type" => "task",
            "data" => %{
              "initiative_id" => ctx.ini.id,
              "parent_id" => ctx.ini.root_task_id,
              "title" => "Fresh"
            }
          }
        ])

      # The fresh batch cleared the residue up front, so nothing stale survives
      # to be flushed onto a later request.
      assert Process.get(@pending, []) == []
    end
  end
end
