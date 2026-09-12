defmodule DoItWeb.Api.ImportsTest do
  @moduledoc """
  Text import — `POST /api/v1/imports` (m03.04 2.3 through 2.6).

  Covers: preview writing nothing while returning the labeled outline, counts,
  style and title; apply into a new Initiative (nesting, done flags,
  descriptions, detected index style, Initiative URL); apply into an existing
  Initiative with and without a `parent_task_id`; a document over the 150-op
  batch cap landing in two transactions with the second batch's children
  correctly parented to the first batch's tasks; the per-source-text
  idempotency record replaying a repeat apply while a different document into
  the same target imports fresh; the single source comment naming the filename
  (or "pasted text"); the preamble landing as the new Initiative's description
  or in the comment for an existing target; the preview diff against an
  existing target (clean when the tree still matches the document; missing,
  extra, completion and order findings once it doesn't; scoped to a
  `parent_task_id`'s children; absent for a new Initiative); the size limits
  (2.6) — an over-long source, too many items and an over-long description each
  refused before a single write, a 200-plus-character title imported whole with
  its overflow in the description, and the limits echoed in a preview; the
  `items` report (6.12.3) naming the source line each created Task came from,
  in whole-document lines through a section import, and an annotated document
  diffing clean and re-importing as its plain self; and the rejection paths —
  empty text, malformed target, stranger, viewer, foreign parent Task.

  Persistence is checked through the domain contexts (not extra API reads) so
  the per-token rate limit (5/window in `config/test.exs`) never bites — each
  request mints a fresh token.
  """
  use DoItWeb.ConnCase, async: true

  alias DoIt.{Accounts, Initiatives, Repo, Tasks}
  alias DoIt.Imports.Import
  alias DoIt.Initiatives.Initiative

  # A small document exercising every mapping at once: a top heading (→ the
  # target, never a wrapper Task), a preamble, numeric markers (→ "numerical"),
  # indent nesting, checkboxes (one ticked), and prose that adds to its item's title.
  @source """
  # Quarterly Plan

  Everything we ship this quarter.

  1. Ship the thing
    1. Draft the spec
       Some detail about the draft.
    2. [x] Book the room
  2. [ ] Tell everyone
  """

  @other_source """
  - Rewrite the onboarding email
  - Delete the old one
  """

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

  # POST an import as `user` and return {status, decoded body}. A fresh token per
  # request keeps the per-token rate limit out of the way.
  defp post_import(user, params) do
    conn =
      build_conn()
      |> bearer(token(user))
      |> put_req_header("content-type", "application/json")
      |> post(~p"/api/v1/imports", params)

    {conn.status, json_response(conn, conn.status)}
  end

  defp titles(initiative_id) do
    initiative_id
    |> Tasks.list_initiative_tasks()
    |> Map.new(&{&1.title, &1})
  end

  defp comment_bodies(task_id) do
    task_id |> Tasks.list_comments() |> Enum.map(& &1.body)
  end

  # What `doitlist.py import` does by default to the document it just
  # imported: every line the response named gets its Task's ` %<id>`.
  defp annotate(text, items) do
    items
    |> Enum.reduce(String.split(text, "\n"), fn %{"line" => line, "id" => id}, lines ->
      List.update_at(lines, line - 1, &(&1 <> " %<#{id}>"))
    end)
    |> Enum.join("\n")
  end

  setup do
    owner = user("owner")
    viewer = user("viewer")
    stranger = user("stranger")

    {:ok, ini} =
      Initiatives.create_initiative(owner, %{"name" => "Live Work"}, agent_access: true)

    {:ok, _} = Initiatives.add_member(ini.id, viewer.id, "viewer")

    %{owner: owner, viewer: viewer, stranger: stranger, ini: ini}
  end

  describe "preview" do
    test "returns the labeled outline, counts, style and title, and writes nothing", %{
      owner: owner,
      ini: ini
    } do
      initiatives_before = Repo.aggregate(Initiative, :count)
      tasks_before = length(Tasks.list_initiative_tasks(ini.id))

      {200, body} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_name" => "Q3 Plan"},
          "preview" => true
        })

      assert body["preview"] == true
      assert body["title"] == "Quarterly Plan"
      assert body["style"] == "numerical"
      assert body["counts"] == %{"items" => 4, "done" => 1, "depth" => 2, "title_overflow" => 0}
      assert body["target"] == %{"kind" => "new_initiative", "name" => "Q3 Plan"}

      # 6.12.3 — a preview creates nothing, so there are no ids to report.
      refute Map.has_key?(body, "items")

      # 2.6.2 — the size rules are readable without spending a failed request.
      assert body["limits"] == %{
               "max_source_bytes" => 1_048_576,
               "max_items" => 2000,
               "max_description" => 8000,
               "max_title" => 200
             }

      assert body["outline"] ==
               """
               1 Ship the thing
                 1.1 Draft the spec
                 1.2 Book the room [x]
               2 Tell everyone\
               """

      refute Map.has_key?(body, "initiative")

      # Nothing written: no Initiative, no Tasks, no import record.
      assert Repo.aggregate(Initiative, :count) == initiatives_before
      assert length(Tasks.list_initiative_tasks(ini.id)) == tasks_before
      assert Repo.aggregate(Import, :count) == 0
    end

    test "against an existing target echoes the resolved target and still writes nothing", %{
      owner: owner,
      ini: ini
    } do
      tasks_before = length(Tasks.list_initiative_tasks(ini.id))

      {200, body} =
        post_import(owner, %{
          "text" => @other_source,
          "target" => %{"initiative_id" => ini.id},
          "preview" => true
        })

      assert body["style"] == "none"
      assert body["title"] == nil
      assert body["outline"] == "Rewrite the onboarding email\nDelete the old one"

      assert body["target"] == %{
               "kind" => "initiative",
               "id" => ini.id,
               "parent_task_id" => nil
             }

      assert length(Tasks.list_initiative_tasks(ini.id)) == tasks_before
      assert Repo.aggregate(Import, :count) == 0
    end
  end

  describe "preview diffing (2.5)" do
    test "the document that built the tree previews clean, and still writes nothing", %{
      owner: owner
    } do
      {200, applied} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_name" => "Q3 Plan"}
        })

      id = applied["initiative"]["id"]
      tasks_before = length(Tasks.list_initiative_tasks(id))
      imports_before = Repo.aggregate(Import, :count)

      {200, body} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_id" => id},
          "preview" => true
        })

      assert body["diff"]["clean"] == true

      assert body["diff"]["summary"] == %{
               "matched" => 4,
               "missing" => 0,
               "extra" => 0,
               "completion" => 0,
               "order" => 0
             }

      # A diff is a read: no new Tasks, no new import record.
      assert length(Tasks.list_initiative_tasks(id)) == tasks_before
      assert Repo.aggregate(Import, :count) == imports_before
    end

    test "a drifted tree reports missing, extra, completion and order", %{owner: owner} do
      {200, applied} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_name" => "Q3 Plan"}
        })

      id = applied["initiative"]["id"]
      initiative = Initiatives.get_initiative(id)
      tasks = titles(id)

      # One of each kind of drift: a completed leaf, an extra live Task, a
      # deleted one, and a reordered sibling.
      {:ok, _} = Tasks.toggle_complete(tasks["Tell everyone"], owner)
      {:ok, _} = Tasks.delete_task(tasks["Book the room"], owner)

      {:ok, surprise} =
        Tasks.create_task(owner, %{
          "initiative_id" => id,
          "parent_id" => initiative.root_task_id,
          "title" => "Surprise chore"
        })

      {:ok, _} =
        Tasks.move_task(tasks["Tell everyone"], owner, %{"position" => 0, "reorder" => true})

      tasks_before = length(Tasks.list_initiative_tasks(id))

      {200, body} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_id" => id},
          "preview" => true
        })

      diff = body["diff"]
      assert diff["clean"] == false

      assert diff["summary"] == %{
               "matched" => 3,
               "missing" => 1,
               "extra" => 1,
               "completion" => 1,
               "order" => 1
             }

      assert diff["missing"] == [
               %{"path" => "Ship the thing > Book the room", "title" => "Book the room"}
             ]

      assert diff["extra"] == [
               %{"path" => "Surprise chore", "title" => "Surprise chore", "id" => surprise.id}
             ]

      assert diff["completion"] == [
               %{
                 "path" => "Tell everyone",
                 "source_done" => false,
                 "live_done" => true,
                 "id" => tasks["Tell everyone"].id
               }
             ]

      assert diff["order"] == [
               %{
                 "parent" => "(root)",
                 "source" => ["Ship the thing", "Tell everyone"],
                 "live" => ["Tell everyone", "Ship the thing"]
               }
             ]

      assert length(Tasks.list_initiative_tasks(id)) == tasks_before
    end

    test "a parent Task target diffs that subtree only", %{owner: owner} do
      {200, applied} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_name" => "Q3 Plan"}
        })

      id = applied["initiative"]["id"]
      ship = titles(id)["Ship the thing"]
      branch = "- Draft the spec\n- [x] Book the room\n"

      {200, scoped} =
        post_import(owner, %{
          "text" => branch,
          "target" => %{"initiative_id" => id, "parent_task_id" => ship.id},
          "preview" => true
        })

      assert scoped["diff"]["clean"] == true
      assert scoped["diff"]["summary"]["matched"] == 2

      # The same document against the whole Initiative sees the top level
      # instead, and disagrees with it — the scope really is the parent Task.
      {200, whole} =
        post_import(owner, %{
          "text" => branch,
          "target" => %{"initiative_id" => id},
          "preview" => true
        })

      assert whole["diff"]["clean"] == false
      assert whole["diff"]["summary"]["missing"] == 2
      assert whole["diff"]["summary"]["extra"] == 2
    end

    test "a new-Initiative preview carries no diff", %{owner: owner} do
      {200, body} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_name" => "Q3 Plan"},
          "preview" => true
        })

      refute Map.has_key?(body, "diff")
    end
  end

  describe "apply into a new Initiative" do
    test "builds the tree, sets the detected style, and returns the Initiative URL", %{
      owner: owner
    } do
      {200, body} =
        post_import(owner, %{
          "text" => @source,
          "filename" => "plan.md",
          "target" => %{"initiative_name" => "Q3 Plan"}
        })

      assert body["preview"] == false
      assert body["batches"] == 1
      assert body["counts"] == %{"items" => 4, "done" => 1, "depth" => 2, "title_overflow" => 0}

      id = body["initiative"]["id"]
      assert body["initiative"]["url"] =~ "/initiatives/#{id}"

      initiative = Initiatives.get_initiative(id)
      assert initiative.name == "Q3 Plan"
      assert initiative.index_style == "numerical"
      # The preamble lands on the target, never as a Task.
      assert initiative.description == "Everything we ship this quarter."

      tasks = titles(id)
      # The root task plus the document's four items — the top heading became
      # the Initiative, not a wrapper Task.
      assert map_size(tasks) == 5

      assert Tasks.ordered_child_ids(initiative.root_task_id) == [
               tasks["Ship the thing"].id,
               tasks["Tell everyone"].id
             ]

      assert Tasks.ordered_child_ids(tasks["Ship the thing"].id) == [
               tasks["Draft the spec"].id,
               tasks["Book the room"].id
             ]

      assert tasks["Book the room"].status == "done"
      assert tasks["Draft the spec"].status != "done"
      assert tasks["Draft the spec"].description == "Some detail about the draft."

      # 2.4: one source comment on the imported root, naming the filename.
      assert comment_bodies(initiative.root_task_id) == ["Imported from plan.md"]
    end

    test "reports the source line each created Task came from (6.12.3)", %{owner: owner} do
      {200, body} =
        post_import(owner, %{
          "text" => @source,
          "target" => %{"initiative_name" => "Q3 Plan"}
        })

      tasks = titles(body["initiative"]["id"])

      # Line 5 of @source is "1. Ship the thing", 6 its nested draft, 8 the
      # ticked room, 9 "Tell everyone" — depth-first, in source order.
      assert body["items"] == [
               %{"line" => 5, "id" => tasks["Ship the thing"].id},
               %{"line" => 6, "id" => tasks["Draft the spec"].id},
               %{"line" => 8, "id" => tasks["Book the room"].id},
               %{"line" => 9, "id" => tasks["Tell everyone"].id}
             ]

      assert @source |> String.split("\n") |> Enum.at(4) == "1. Ship the thing"
    end

    test "without a filename the source comment says pasted text", %{owner: owner} do
      {200, body} =
        post_import(owner, %{
          "text" => @other_source,
          "target" => %{"initiative_name" => "Inbox"}
        })

      initiative = Initiatives.get_initiative(body["initiative"]["id"])
      assert initiative.index_style == "none"
      assert comment_bodies(initiative.root_task_id) == ["Imported from pasted text"]
    end
  end

  describe "apply into an existing Initiative" do
    test "lands top-level under the root and comments there", %{owner: owner, ini: ini} do
      {200, body} =
        post_import(owner, %{
          "text" => @source,
          "filename" => "q3.md",
          "target" => %{"initiative_id" => ini.id}
        })

      assert body["initiative"]["id"] == ini.id
      assert body["batches"] == 1

      tasks = titles(ini.id)

      assert Tasks.ordered_child_ids(ini.root_task_id) == [
               tasks["Ship the thing"].id,
               tasks["Tell everyone"].id
             ]

      assert tasks["Draft the spec"].parent_id == tasks["Ship the thing"].id

      # The existing Initiative keeps its own description; the preamble rides
      # along in the source comment instead.
      assert Initiatives.get_initiative(ini.id).description in [nil, ""]

      assert comment_bodies(ini.root_task_id) ==
               ["Imported from q3.md\n\nEverything we ship this quarter."]
    end

    test "lands under a parent Task when one is given", %{owner: owner, ini: ini} do
      {:ok, parent} =
        Tasks.create_task(owner, %{
          "initiative_id" => ini.id,
          "parent_id" => ini.root_task_id,
          "title" => "Existing branch"
        })

      {200, body} =
        post_import(owner, %{
          "text" => @other_source,
          "target" => %{"initiative_id" => ini.id, "parent_task_id" => parent.id}
        })

      assert body["initiative"]["id"] == ini.id

      assert body["target"] == %{
               "kind" => "initiative",
               "id" => ini.id,
               "parent_task_id" => parent.id
             }

      tasks = titles(ini.id)

      assert Tasks.ordered_child_ids(parent.id) == [
               tasks["Rewrite the onboarding email"].id,
               tasks["Delete the old one"].id
             ]

      # The comment goes on the imported root — here, the parent Task.
      assert comment_bodies(parent.id) == ["Imported from pasted text"]
      assert comment_bodies(ini.root_task_id) == []
    end
  end

  describe "batching past the operation cap" do
    @tag timeout: 300_000
    test "splits into cap-sized transactions and reparents across the boundary", %{owner: owner} do
      # 90 parents each with one child → 180 task ops plus the Initiative op.
      # Emission is depth-first (Parent 1, Child 1, Parent 2, …), so the 150-op
      # first batch ends on "Parent 75" and the second batch OPENS with its
      # child — the cross-batch parent_lid rewrite — while its own roots still
      # reference the first batch's Initiative through initiative_lid.
      text =
        Enum.map_join(1..90, fn i -> "- Parent #{i}\n  - Child #{i}\n" end)

      {200, body} =
        post_import(owner, %{
          "text" => text,
          "target" => %{"initiative_name" => "Big Plan"}
        })

      assert body["batches"] == 2
      assert body["counts"]["items"] == 180

      id = body["initiative"]["id"]
      initiative = Initiatives.get_initiative(id)
      tasks = titles(id)
      assert map_size(tasks) == 181

      # The boundary case: a second-batch child under a first-batch parent.
      assert tasks["Child 75"].parent_id == tasks["Parent 75"].id
      # A second-batch root still resolves the first batch's Initiative.
      assert tasks["Parent 90"].parent_id == initiative.root_task_id
      assert tasks["Child 90"].parent_id == tasks["Parent 90"].id
      assert length(Tasks.ordered_child_ids(initiative.root_task_id)) == 90
    end
  end

  describe "limits (2.6)" do
    test "source text over the byte limit is refused before anything is written", %{
      owner: owner,
      ini: ini
    } do
      # One small item carrying a megabyte of prose: the source-size rule fires
      # first, so an oversized document never reaches a write.
      text = "- Item\n" <> String.duplicate("x", 1_048_600)

      {422, body} =
        post_import(owner, %{"text" => text, "target" => %{"initiative_id" => ini.id}})

      assert body["error"]["message"] =~ "#{byte_size(text)} bytes"
      assert body["error"]["message"] =~ "1048576"
      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
      assert Repo.aggregate(Import, :count) == 0
    end

    test "more items than the cap are refused before anything is written", %{owner: owner} do
      limit = DoItWeb.Api.Imports.limits()["max_items"]
      text = Enum.map_join(1..(limit + 1), fn i -> "- Item #{i}\n" end)

      {422, body} =
        post_import(owner, %{"text" => text, "target" => %{"initiative_name" => "Too big"}})

      assert body["error"]["message"] =~ "#{limit + 1} items"
      assert body["error"]["message"] =~ "#{limit}"
      # Only the setup Initiative: the refusal comes before the first batch.
      assert Repo.aggregate(Initiative, :count) == 1
      assert Repo.aggregate(Import, :count) == 0
    end

    test "an item whose description exceeds the cap is refused, named by its path", %{
      owner: owner,
      ini: ini
    } do
      text = """
      - Parent
        - Child
          #{String.duplicate("x", 8001)}
      """

      {422, body} =
        post_import(owner, %{"text" => text, "target" => %{"initiative_id" => ini.id}})

      assert body["error"]["message"] =~ "\"Parent > Child\""
      assert body["error"]["message"] =~ "8001-character"
      assert body["error"]["message"] =~ "8000"
      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
      assert Repo.aggregate(Import, :count) == 0
    end

    test "a title past 200 characters imports whole, the overflow in the description", %{
      owner: owner,
      ini: ini
    } do
      {200, body} =
        post_import(owner, %{
          "text" => "- #{String.duplicate("x", 300)}\n",
          "target" => %{"initiative_id" => ini.id}
        })

      assert body["counts"]["title_overflow"] == 1

      task = titles(ini.id)[String.duplicate("x", 200)]
      assert task
      assert task.description == String.duplicate("x", 100)
    end
  end

  describe "idempotency" do
    test "a repeat apply replays the stored body and writes nothing new", %{
      owner: owner,
      ini: ini
    } do
      params = %{
        "text" => @source,
        "filename" => "plan.md",
        "target" => %{"initiative_id" => ini.id}
      }

      {200, first} = post_import(owner, params)
      tasks_after_first = length(Tasks.list_initiative_tasks(ini.id))

      {200, second} = post_import(owner, params)

      assert second["replayed"] == true
      assert Map.delete(second, "replayed") == first
      # The replay still names the lines and ids, so the write-back can finish
      # a run whose first attempt got the response but not the file (6.12.4).
      assert second["items"] == first["items"]

      assert length(Tasks.list_initiative_tasks(ini.id)) == tasks_after_first

      assert comment_bodies(ini.root_task_id) ==
               ["Imported from plan.md\n\nEverything we ship this quarter."]

      assert Repo.aggregate(Import, :count) == 1
    end

    test "a different document into the same target is a new import", %{owner: owner, ini: ini} do
      {200, _} =
        post_import(owner, %{"text" => @source, "target" => %{"initiative_id" => ini.id}})

      {200, body} =
        post_import(owner, %{"text" => @other_source, "target" => %{"initiative_id" => ini.id}})

      refute Map.has_key?(body, "replayed")
      assert Map.has_key?(titles(ini.id), "Rewrite the onboarding email")
      assert Repo.aggregate(Import, :count) == 2
      assert length(comment_bodies(ini.root_task_id)) == 2
    end
  end

  describe "section (6.10)" do
    @sectioned """
    # Milestone

    Front matter.

    ## Arc 3

    1. Old work

    ## Arc 4

    1. First item
       1. Nested item
    2. Second item

    ## Arc 5

    1. Later work
    """

    test "a preview reports the section and an outline starting at index 1", %{
      owner: owner,
      ini: ini
    } do
      {200, body} =
        post_import(owner, %{
          "text" => @sectioned,
          "target" => %{"initiative_id" => ini.id, "section" => "## Arc 4"},
          "preview" => true
        })

      assert body["outline"] == "1 First item\n  1.1 Nested item\n2 Second item"
      assert body["title"] == nil
      assert body["counts"]["items"] == 3

      assert body["target"] == %{
               "kind" => "initiative",
               "id" => ini.id,
               "parent_task_id" => nil,
               "section" => "## Arc 4"
             }

      assert Repo.aggregate(Import, :count) == 0
    end

    test "an apply lands the section's first child at index 1, heading omitted", %{
      owner: owner,
      ini: ini
    } do
      {200, body} =
        post_import(owner, %{
          "text" => @sectioned,
          "filename" => "m03.md",
          "target" => %{"initiative_id" => ini.id, "section" => "Arc 4"}
        })

      assert body["target"]["section"] == "Arc 4"
      assert %Import{response: %{"target" => %{"section" => "Arc 4"}}} = Repo.one!(Import)

      by_title = titles(ini.id)
      refute Map.has_key?(by_title, "Arc 4")
      refute Map.has_key?(by_title, "Old work")
      refute Map.has_key?(by_title, "Later work")

      # The section's first child is the root's first child: index 1.
      assert Tasks.ordered_child_ids(ini.root_task_id) == [
               by_title["First item"].id,
               by_title["Second item"].id
             ]

      assert by_title["Nested item"].parent_id == by_title["First item"].id
    end

    test "items report whole-document lines, not the slice's (6.12.3)", %{
      owner: owner,
      ini: ini
    } do
      {200, body} =
        post_import(owner, %{
          "text" => @sectioned,
          "target" => %{"initiative_id" => ini.id, "section" => "Arc 4"}
        })

      by_title = titles(ini.id)

      assert body["items"] == [
               %{"line" => 11, "id" => by_title["First item"].id},
               %{"line" => 12, "id" => by_title["Nested item"].id},
               %{"line" => 13, "id" => by_title["Second item"].id}
             ]

      # Line 11 of the whole document, not line 2 of the slice.
      assert @sectioned |> String.split("\n") |> Enum.at(10) == "1. First item"
    end

    test "a missing or ambiguous heading is 422 naming it, and writes nothing", %{
      owner: owner,
      ini: ini
    } do
      {422, missing} =
        post_import(owner, %{
          "text" => @sectioned,
          "target" => %{"initiative_id" => ini.id, "section" => "Arc 9"}
        })

      assert missing["error"]["message"] =~ ~s(No heading "Arc 9")

      {422, ambiguous} =
        post_import(owner, %{
          "text" => @sectioned <> "\n## Arc 4\n\n1. Again\n",
          "target" => %{"initiative_id" => ini.id, "section" => "Arc 4"}
        })

      assert ambiguous["error"]["message"] =~ ~s("Arc 4" appears 2 times)

      {422, blank} =
        post_import(owner, %{
          "text" => @sectioned,
          "target" => %{"initiative_name" => "X", "section" => "  "}
        })

      assert blank["error"]["message"] =~ "blank"

      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
      assert Repo.aggregate(Import, :count) == 0
    end
  end

  describe "annotated mirrors (6.12.5)" do
    test "an annotated document diffs clean and re-imports as its plain self", %{
      owner: owner,
      ini: ini
    } do
      {200, first} =
        post_import(owner, %{"text" => @source, "target" => %{"initiative_id" => ini.id}})

      annotated = annotate(@source, first["items"])
      ship = titles(ini.id)["Ship the thing"]
      assert annotated =~ "1. Ship the thing %<#{ship.id}>"

      {200, preview} =
        post_import(owner, %{
          "text" => annotated,
          "target" => %{"initiative_id" => ini.id},
          "preview" => true
        })

      assert preview["diff"]["clean"] == true
      assert preview["counts"] == first["counts"]
      assert preview["outline"] == first["outline"]

      # And imported fresh, the annotations are not part of any title.
      {200, copy} =
        post_import(owner, %{"text" => annotated, "target" => %{"initiative_name" => "Copy"}})

      copied = Tasks.list_initiative_tasks(copy["initiative"]["id"])
      refute Enum.any?(copied, &(&1.title =~ "%<"))
      assert Enum.any?(copied, &(&1.title == "Ship the thing"))
    end
  end

  describe "rejections" do
    test "blank text and text with no items are both 422", %{owner: owner} do
      {422, blank} =
        post_import(owner, %{"text" => "   \n\n", "target" => %{"initiative_name" => "X"}})

      assert blank["error"]["status"] == 422

      {422, prose} =
        post_import(owner, %{
          "text" => "Just a paragraph with nothing to do in it.\n",
          "target" => %{"initiative_name" => "X"}
        })

      assert prose["error"]["message"] =~ "No tasks found"
      assert Repo.aggregate(Import, :count) == 0
    end

    test "a malformed target is 422", %{owner: owner, ini: ini} do
      {422, both} =
        post_import(owner, %{
          "text" => @other_source,
          "target" => %{"initiative_name" => "X", "initiative_id" => ini.id}
        })

      assert both["error"]["message"] =~ "both"

      {422, neither} = post_import(owner, %{"text" => @other_source, "target" => %{}})
      assert neither["error"]["message"] =~ "neither"

      {422, missing} = post_import(owner, %{"text" => @other_source})
      assert missing["error"]["message"] =~ "target"

      assert Repo.aggregate(Initiative, :count) == 1
    end

    test "a non-editor is 403 and an unknown Initiative is 404", %{
      owner: owner,
      viewer: viewer,
      stranger: stranger,
      ini: ini
    } do
      params = %{"text" => @other_source, "target" => %{"initiative_id" => ini.id}}

      # DoItWeb.Api.Authz's policy, inherited unchanged: a real Initiative the
      # caller can't edit is 403 (stranger and viewer alike); 404 is reserved
      # for an id that resolves to nothing the token may see.
      assert {403, stranger_body} = post_import(stranger, params)
      assert stranger_body["error"]["code"] == "forbidden"
      assert {403, viewer_body} = post_import(viewer, params)
      assert viewer_body["error"]["code"] == "forbidden"

      assert {404, missing} =
               post_import(owner, %{
                 "text" => @other_source,
                 "target" => %{"initiative_id" => ini.id + 10_000}
               })

      assert missing["error"]["status"] == 404
      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
    end

    test "a batch that fails reports the failure and records nothing", %{owner: owner} do
      # The Initiative NAME comes from the caller, not the document, so it is the
      # one length the 2.6 pre-write checks don't cover — over the schema's 120
      # it fails inside the batch: the transaction rolls back, the response names
      # the failed batch, and no import record is stored, so an honest retry
      # re-runs instead of replaying a failure.
      {422, body} =
        post_import(owner, %{
          "text" => @other_source,
          "target" => %{"initiative_name" => String.duplicate("n", 250)}
        })

      assert body["applied_batches"] == 0
      assert body["failed_batch"] == 1
      # The denominator travels with the counts, so a client can say "0 of 1"
      # without parsing the message.
      assert body["total_batches"] == 1
      # Nothing committed, so there is no Initiative to point at.
      refute Map.has_key?(body, "initiative")

      assert [%{"status" => "error", "index" => 0} | rest] = body["results"]
      assert Enum.all?(rest, &(&1["status"] == "not_applied"))

      assert Repo.aggregate(Import, :count) == 0
      assert Repo.aggregate(Initiative, :count) == 1
    end

    test "a parent Task from another Initiative is 404", %{owner: owner, ini: ini} do
      {:ok, other} =
        Initiatives.create_initiative(owner, %{"name" => "Elsewhere"}, agent_access: true)

      {:ok, foreign} =
        Tasks.create_task(owner, %{
          "initiative_id" => other.id,
          "parent_id" => other.root_task_id,
          "title" => "Foreign branch"
        })

      {404, body} =
        post_import(owner, %{
          "text" => @other_source,
          "target" => %{"initiative_id" => ini.id, "parent_task_id" => foreign.id}
        })

      assert body["error"]["status"] == 404
      assert length(Tasks.list_initiative_tasks(ini.id)) == 1
      assert length(Tasks.list_initiative_tasks(other.id)) == 2
    end
  end
end
