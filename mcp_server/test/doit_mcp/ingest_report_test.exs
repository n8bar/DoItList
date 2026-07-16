defmodule DoitMcp.IngestReportTest do
  @moduledoc """
  The `ingest_report` lint facts (m03.03 item 5.5) — the pure computation
  (`DoitMcp.IngestReport.build/2`) over a fixture tree-read JSON plus fixture
  comments, one case per fact class, plus the tool wrapper
  (`DoitMcp.Tools.IngestReport`): compose the tree read and the comment-thread
  reads, reply with the report, register under `ingest_report`.

  Facts only — every assertion is a count, an id, or a matched substring;
  the module under test carries no verdicts or thresholds.
  """

  use ExUnit.Case, async: true

  alias Anubis.Server.Response
  alias DoitMcp.IngestReport

  # A decoded `GET /api/v1/initiatives/:id` body (string keys, as off the wire).
  # Shape: 1 (branch: 1.1 leaf, 1.2 branch over 1.2.1 leaf), 2 (leaf), 3 (leaf).
  @tree %{
    "id" => 42,
    "name" => "Fixture Initiative",
    "index_style" => "numerical",
    "ai_knobs" => nil,
    "root_task_id" => 100,
    "tasks" => [
      %{
        "id" => 1,
        "title" => "Alpha",
        "index" => "1",
        "description" => "start with docs/m03-api/plan.md and lib/doit/tasks.ex",
        "comment_count" => 2,
        "children" => [
          %{
            "id" => 11,
            "title" => "Prep",
            "index" => "1.1",
            "description" => nil,
            "comment_count" => 0,
            "children" => []
          },
          %{
            "id" => 12,
            "title" => "Mid",
            "index" => "1.2",
            "description" => "   ",
            "comment_count" => 1,
            "children" => [
              %{
                "id" => 121,
                "title" => "Deep",
                "index" => "1.2.1",
                "description" => "see M3 and 1.2.3, then task 7",
                "comment_count" => 0,
                "children" => []
              }
            ]
          }
        ]
      },
      %{
        "id" => 2,
        "title" => "M12 kickoff",
        "index" => "2",
        "description" => "already linked %<5> here",
        "comment_count" => 0,
        "children" => []
      },
      %{
        "id" => 3,
        "title" => "Ship %<9> now",
        "index" => "3",
        "description" => nil,
        "comment_count" => 0,
        "children" => []
      }
    ]
  }

  describe "build/1 — shape facts" do
    test "task count, leaf/branch split, depth histogram, top-level index range" do
      report = IngestReport.build(@tree)

      assert report.initiative_id == 42
      assert report.task_count == 6
      assert report.leaf_count == 4
      assert report.branch_count == 2
      assert report.depth_histogram == %{"0" => 3, "1" => 2, "2" => 1}
      assert report.top_level_index_range == "1..3"
    end

    test "an empty tree measures as zeroes, no ranges" do
      report = IngestReport.build(%{"id" => 7, "ai_knobs" => "x", "tasks" => []})

      assert report.task_count == 0
      assert report.leaf_count == 0
      assert report.branch_count == 0
      assert report.depth_histogram == %{}
      assert report.top_level_index_range == nil
      assert report.no_description_task_ids == []
      assert report.duplicate_descriptions == []
      assert report.top_rank_counts == []
      assert report.top_rank_no_comment_task_ids == []
      assert report.unanchored_reference_candidates == []
      assert report.path_like_strings == []
      assert report.journal_markers_in_descriptions == []
      assert report.long_comments == []
    end
  end

  describe "build/1 — description coverage" do
    test "counts with/without (blank counts as without) and lists the naked ids in tree order" do
      report = IngestReport.build(@tree)

      assert report.with_description == 3
      assert report.without_description == 3
      assert report.no_description_task_ids == [11, 12, 3]
    end
  end

  describe "build/1 — duplicate descriptions" do
    test "groups exact repeats: preview + count + tree-order ids, sorted by count descending" do
      tree = %{
        "id" => 1,
        "ai_knobs" => nil,
        "tasks" => [
          leaf(1, "other"),
          leaf(2, "same"),
          leaf(3, "unique"),
          leaf(4, "same"),
          leaf(5, "other"),
          leaf(6, "same"),
          # Exact-string grouping — a trailing space is a different string.
          leaf(7, "other ")
        ]
      }

      assert IngestReport.build(tree).duplicate_descriptions == [
               %{description: "same", count: 3, task_ids: [2, 4, 6]},
               %{description: "other", count: 2, task_ids: [1, 5]}
             ]
    end

    test "nil, empty, and whitespace-only descriptions never group" do
      tree = %{
        "id" => 1,
        "ai_knobs" => nil,
        "tasks" => [
          leaf(1, nil),
          leaf(2, nil),
          leaf(3, ""),
          leaf(4, ""),
          leaf(5, "   "),
          leaf(6, "   ")
        ]
      }

      assert IngestReport.build(tree).duplicate_descriptions == []
    end

    test "no duplicates measures as an empty list" do
      assert IngestReport.build(@tree).duplicate_descriptions == []
    end

    test "long repeated strings preview to 120 characters" do
      long = String.duplicate("x", 150)
      tree = %{"id" => 1, "ai_knobs" => nil, "tasks" => [leaf(1, long), leaf(2, long)]}

      assert [%{description: preview, count: 2, task_ids: [1, 2]}] =
               IngestReport.build(tree).duplicate_descriptions

      assert preview == String.duplicate("x", 120) <> "…"
    end

    test "the entry list and each entry's id list are capped" do
      # One description shared by 25 tasks plus 21 distinct pair-duplicates:
      # the big group sorts first with capped ids, and the 22-entry list
      # itself caps at 20 + tail. Pair ties keep tree order.
      crowd = for i <- 1..25, do: leaf(1000 + i, "swamped")
      pairs = for i <- 1..21, j <- 0..1, do: leaf(i * 10 + j, "dup #{i}")

      report = IngestReport.build(%{"id" => 9, "ai_knobs" => nil, "tasks" => crowd ++ pairs})

      assert [first | _] = report.duplicate_descriptions

      assert first == %{
               description: "swamped",
               count: 25,
               task_ids: Enum.map(1..20, &(1000 + &1)) ++ ["and 5 more"]
             }

      assert Enum.at(report.duplicate_descriptions, 1) ==
               %{description: "dup 1", count: 2, task_ids: [10, 11]}

      assert length(report.duplicate_descriptions) == 21
      assert List.last(report.duplicate_descriptions) == "and 2 more"
    end
  end

  describe "build/1 — top-rank counts" do
    test "one entry per top-rank task: subtree size + done count, tree order" do
      # @tree carries no done flags — everything counts as not done.
      assert IngestReport.build(@tree).top_rank_counts == [
               %{task_id: 1, title: "Alpha", subtree_task_count: 4, subtree_done_count: 0},
               %{task_id: 2, title: "M12 kickoff", subtree_task_count: 1, subtree_done_count: 0},
               %{task_id: 3, title: "Ship %<9> now", subtree_task_count: 1, subtree_done_count: 0}
             ]
    end

    test "done counts the wire done flag across the whole subtree, the top task included" do
      tree = %{
        "id" => 1,
        "ai_knobs" => nil,
        "tasks" => [
          leaf(1, nil, %{
            "title" => "Alpha",
            "done" => true,
            "children" => [
              leaf(11, nil, %{"done" => true}),
              leaf(12, nil, %{
                "done" => false,
                "children" => [leaf(121, nil, %{"done" => true})]
              })
            ]
          }),
          leaf(2, nil, %{"title" => "Beta", "done" => false})
        ]
      }

      assert IngestReport.build(tree).top_rank_counts == [
               %{task_id: 1, title: "Alpha", subtree_task_count: 4, subtree_done_count: 3},
               %{task_id: 2, title: "Beta", subtree_task_count: 1, subtree_done_count: 0}
             ]
    end
  end

  describe "build/1 — provenance coverage" do
    test "lists top-rank (depth 0) tasks with zero comments; deeper zeroes don't qualify" do
      report = IngestReport.build(@tree)

      # 1 has comments; 11 and 121 have zero but sit deeper.
      assert report.top_rank_no_comment_task_ids == [2, 3]
    end
  end

  describe "build/1 — un-anchored reference candidates" do
    test "flags M<n>, dotted index paths, and 'task N' in titles + descriptions" do
      report = IngestReport.build(@tree)

      assert report.unanchored_reference_candidates == [
               %{task_id: 121, field: "description", matched_text: "M3"},
               %{task_id: 121, field: "description", matched_text: "1.2.3"},
               %{task_id: 121, field: "description", matched_text: "task 7"},
               %{task_id: 2, field: "title", matched_text: "M12"}
             ]
    end

    test "text inside a %<id> token is never a candidate" do
      # A field whose only reference-shaped content is the resolved token
      # (tasks 2's description, 3's title in @tree) contributes nothing —
      # covered by the exact list above. Sharper: a candidate-shaped string
      # adjacent to a token must not merge with the token's digits.
      tree = %{
        "id" => 1,
        "ai_knobs" => nil,
        "tasks" => [
          %{
            "id" => 5,
            "title" => "M4 next to %<41>",
            "index" => "1",
            "description" => "1.%<2> stays un-matched; literal %1.2 does not",
            "comment_count" => 0,
            "children" => []
          }
        ]
      }

      report = IngestReport.build(tree)

      assert report.unanchored_reference_candidates == [
               %{task_id: 5, field: "title", matched_text: "M4"},
               %{task_id: 5, field: "description", matched_text: "1.2"}
             ]
    end
  end

  describe "build/1 — path-like strings" do
    test "reports slash-separated path shapes in descriptions" do
      report = IngestReport.build(@tree)

      assert report.path_like_strings == [
               %{task_id: 1, matched_text: "docs/m03-api/plan.md"},
               %{task_id: 1, matched_text: "lib/doit/tasks.ex"}
             ]
    end
  end

  describe "build/2 — journal markers in descriptions" do
    test "flags each marker at line start or after whitespace, uniq per task, in tree order" do
      tree = %{
        "id" => 1,
        "ai_knobs" => nil,
        "tasks" => [
          %{
            "id" => 5,
            "title" => "Decision: markers in titles don't count",
            "index" => "1",
            "description" => "Decision: batch it.\nVerified: green. Decision: again.",
            "comment_count" => 0,
            "children" => []
          },
          %{
            "id" => 6,
            "title" => "Beta",
            "index" => "2",
            "description" => "Locked decisions: cap at 150. See Verification: notes.",
            "comment_count" => 0,
            "children" => []
          }
        ]
      }

      report = IngestReport.build(tree)

      assert report.journal_markers_in_descriptions == [
               %{task_id: 5, matched_text: "Decision:"},
               %{task_id: 5, matched_text: "Verified:"},
               %{task_id: 6, matched_text: "Locked decisions:"},
               %{task_id: 6, matched_text: "Verification:"}
             ]
    end

    test "case-sensitive and never mid-word" do
      tree = %{
        "id" => 1,
        "ai_knobs" => nil,
        "tasks" => [
          %{
            "id" => 7,
            "title" => "Gamma",
            "index" => "1",
            "description" => "decision: lowercase, Redecision: mid-word, indecisions everywhere",
            "comment_count" => 0,
            "children" => []
          }
        ]
      }

      assert IngestReport.build(tree).journal_markers_in_descriptions == []
    end
  end

  describe "build/2 — long comments" do
    test "lists comment id + task id past 300 characters; tombstone nil bodies never measure" do
      comments = [
        %{"id" => 31, "task_id" => 100, "body" => String.duplicate("a", 301)},
        %{"id" => 32, "task_id" => 1, "body" => String.duplicate("b", 300)},
        %{"id" => 33, "task_id" => 12, "body" => nil},
        %{"id" => 34, "task_id" => 12, "body" => String.duplicate("c", 500)}
      ]

      report = IngestReport.build(@tree, comments)

      assert report.long_comments == [
               %{comment_id: 31, task_id: 100},
               %{comment_id: 34, task_id: 12}
             ]
    end

    test "without a comments list the fact is empty, never absent" do
      assert IngestReport.build(@tree).long_comments == []
    end
  end

  describe "comment_thread_ids/1" do
    test "root task first, then commented tree tasks in tree order" do
      assert IngestReport.comment_thread_ids(@tree) == [100, 1, 12]
    end

    test "no root id, no commented tasks — empty" do
      assert IngestReport.comment_thread_ids(%{"id" => 7, "tasks" => []}) == []
    end
  end

  describe "build/1 — context facts" do
    test "ai_knobs presence is a boolean, never the content" do
      assert IngestReport.build(@tree).ai_knobs_set == false

      assert IngestReport.build(Map.put(@tree, "ai_knobs", "deploy_day: friday")).ai_knobs_set ==
               true

      assert IngestReport.build(Map.put(@tree, "ai_knobs", "   ")).ai_knobs_set == false
    end
  end

  describe "build/1 — capped lists" do
    test "every list carries the first 20 plus an 'and N more' tail" do
      tasks =
        for i <- 1..25 do
          %{
            "id" => i,
            "title" => "M#{i} thing",
            "index" => "#{i}",
            "description" => nil,
            "comment_count" => 0,
            "children" => []
          }
        end

      report = IngestReport.build(%{"id" => 9, "ai_knobs" => nil, "tasks" => tasks})

      assert report.no_description_task_ids == Enum.to_list(1..20) ++ ["and 5 more"]
      assert report.top_rank_no_comment_task_ids == Enum.to_list(1..20) ++ ["and 5 more"]

      assert length(report.top_rank_counts) == 21

      assert List.first(report.top_rank_counts) ==
               %{task_id: 1, title: "M1 thing", subtree_task_count: 1, subtree_done_count: 0}

      assert List.last(report.top_rank_counts) == "and 5 more"

      assert length(report.unanchored_reference_candidates) == 21

      assert Enum.take(report.unanchored_reference_candidates, 20) ==
               Enum.map(1..20, &%{task_id: &1, field: "title", matched_text: "M#{&1}"})

      assert List.last(report.unanchored_reference_candidates) == "and 5 more"
    end
  end

  describe "the ingest_report tool" do
    test "composes the tree read plus the comment-thread reads and replies with the report JSON" do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        assert conn.method == "GET"

        case conn.request_path do
          "/api/v1/initiatives/42" ->
            Req.Test.json(conn, %{"data" => @tree})

          # `comment_thread_ids(@tree)` — root task 100, commented tasks 1, 12.
          "/api/v1/initiatives/42/tasks/100/comments" ->
            Req.Test.json(conn, %{
              "data" => [%{"id" => 900, "task_id" => 100, "body" => String.duplicate("a", 301)}]
            })

          "/api/v1/initiatives/42/tasks/1/comments" ->
            Req.Test.json(conn, %{
              "data" => [
                %{"id" => 901, "task_id" => 1, "body" => "short"},
                %{"id" => 902, "task_id" => 1, "body" => "also short"}
              ]
            })

          "/api/v1/initiatives/42/tasks/12/comments" ->
            Req.Test.json(conn, %{"data" => [%{"id" => 903, "task_id" => 12, "body" => "ok"}]})
        end
      end)

      frame = %{test: true}

      assert {:reply, %Response{} = response, ^frame} =
               DoitMcp.Tools.IngestReport.execute(%{initiative_id: 42}, frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == false
      assert [%{"type" => "text", "text" => text}] = protocol["content"]

      report = Jason.decode!(text)
      assert report["initiative_id"] == 42
      assert report["task_count"] == 6
      assert report["depth_histogram"] == %{"0" => 3, "1" => 2, "2" => 1}
      assert report["no_description_task_ids"] == [11, 12, 3]
      assert report["duplicate_descriptions"] == []

      assert List.first(report["top_rank_counts"]) ==
               %{
                 "task_id" => 1,
                 "title" => "Alpha",
                 "subtree_task_count" => 4,
                 "subtree_done_count" => 0
               }

      assert report["long_comments"] == [%{"comment_id" => 900, "task_id" => 100}]
      assert report["ai_knobs_set"] == false
    end

    test "surfaces a failed comment-thread read as a tool error, never a partial report" do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        case conn.request_path do
          "/api/v1/initiatives/42" ->
            Req.Test.json(conn, %{"data" => @tree})

          _comments ->
            conn
            |> Plug.Conn.put_status(403)
            |> Req.Test.json(%{"error" => %{"code" => "forbidden", "message" => "forbidden"}})
        end
      end)

      frame = %{test: true}

      assert {:reply, response, ^frame} =
               DoitMcp.Tools.IngestReport.execute(%{initiative_id: 42}, frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert protocol["content"] == [%{"type" => "text", "text" => "(403) forbidden"}]
    end

    test "surfaces an API error as a tool error" do
      Req.Test.stub(DoitMcp.Client, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{"error" => %{"code" => "not_found", "message" => "not found"}})
      end)

      frame = %{test: true}

      assert {:reply, response, ^frame} =
               DoitMcp.Tools.IngestReport.execute(%{initiative_id: 42}, frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert protocol["content"] == [%{"type" => "text", "text" => "(404) not found"}]
    end

    test "registers on the server as ingest_report with an object input schema" do
      assert %{"type" => "object"} = DoitMcp.Tools.IngestReport.input_schema()

      assert "ingest_report" in Enum.map(DoitMcp.Server.__components__(:tool), & &1.name)
    end
  end

  # A leaf-task wire map; `extra` overrides any key (including "children").
  defp leaf(id, description, extra \\ %{}) do
    Map.merge(
      %{
        "id" => id,
        "title" => "Task #{id}",
        "index" => "#{id}",
        "description" => description,
        "comment_count" => 0,
        "children" => []
      },
      extra
    )
  end
end
