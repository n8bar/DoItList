defmodule DoitMcp.ApplyOperationsGateTest do
  @moduledoc """
  The no-stop import model (m03.04 2.8.4): an import-shaped batch applies
  without a stop once it carries a `readback`, which the apply posts as a
  provenance comment on the target Initiative's root task; a batch without
  one meets an agent-facing refusal teaching the re-call. Shape refusals
  stay, overridable only by the operator's chat confirm
  (`operator_confirmed: true`), stamped into the record.
  """
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.ImportGate
  alias DoitMcp.Tools.ApplyOperations

  @threshold ImportGate.threshold()
  @frame %{test: true}

  # The classifier ships armed (DOITLIST_IMPORT_GATE=off opts out); pin it on
  # here so these behavior tests stay deterministic against the container's
  # ambient environment.
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  # Tests that settle a record (one readback per Initiative per session)
  # start the session memory; everything else runs memory-less (Counter
  # degrades to zero/no-op), i.e. single-batch semantics.
  defp start_gate_state do
    counter = :"#{__MODULE__}.Counter"
    start_supervised!({DoitMcp.ImportGate.Counter, name: counter})

    previous_counter = Application.fetch_env(:doit_mcp, :import_gate_counter)
    Application.put_env(:doit_mcp, :import_gate_counter, counter)

    on_exit(fn ->
      case previous_counter do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_counter, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_counter)
      end
    end)
  end

  # A bootstrap with its first task arriving done — the interview's
  # 1-complete declaration shape (`declared/3` below); the all-open form
  # drives the first-import describe.
  defp new_initiative_batch(task_count) do
    [initiative, %{"data" => data} = first | rest] = all_open_bootstrap(task_count)
    [initiative, %{first | "data" => Map.put(data, "done", true)} | rest]
  end

  defp all_open_bootstrap(task_count) do
    [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
      for i <- 1..task_count do
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "t#{i}",
          "data" => %{"initiative_lid" => "i", "title" => "task #{i}"}
        }
      end
  end

  defp existing_initiative_batch(task_count, initiative_id) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"initiative_id" => initiative_id, "title" => "task #{i}"}
      }
    end
  end

  defp parent_anchored_batch(task_count, parent_id) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"parent_id" => parent_id, "title" => "task #{i}"}
      }
    end
  end

  # A file-mirror shape into an existing Initiative: path-like titles plus
  # whole-file-sized descriptions, over the mirror minimum.
  defp mirror_batch(initiative_id) do
    for i <- 1..12 do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{
          "initiative_id" => initiative_id,
          "title" => "docs/f#{i}.md",
          "description" => String.duplicate("x", 2_100) <> "#{i}"
        }
      }
    end
  end

  defp checklist_batch(initiative_id) do
    [
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t1",
        "data" => %{
          "initiative_id" => initiative_id,
          "title" => "Set up the environment",
          "description" => "Steps:\n- [ ] install deps\n- [ ] configure env"
        }
      }
    ]
  end

  # Serves GET /initiatives/:id/task_count — the DB-window pressure read
  # (m03.04 3.1 iteration 2) — ahead of a stub's other clauses. `extra`
  # merges further task_count facts (e.g. initiative_index_style); the
  # count-only default models a response WITHOUT the style key, so tests on
  # it exercise the record's fail-open no-line lane.
  defp with_pressure(conn, pressure, fallback, extra) do
    if conn.method == "GET" and String.ends_with?(conn.request_path, "/task_count") do
      Req.Test.json(conn, %{"data" => Map.merge(%{"count" => pressure}, extra)})
    else
      fallback.(conn)
    end
  end

  # POST /operations is captured to the test process as {:operations_post,
  # decoded_body} — the readback record is itself an operations POST (one
  # comment op), so tests assert it landed by reading their own mailbox. A
  # batch that bootstraps an Initiative (lid "i") echoes the created id and
  # its root_task_id, the wire shape for creates; other posts (later chunks,
  # the record comment) return empty results. The initiative LIST serves the
  # existing target's root_task_id (the record's lookup) and no repo_marker,
  # so no marker suggestion rides these assertions.
  defp stub_apply(opts \\ []) do
    pressure = Keyword.get(opts, :pressure, 0)
    extra = Keyword.get(opts, :task_count_extra, %{})
    created_id = Keyword.get(opts, :created_id, 57)
    created_root = Keyword.get(opts, :created_root, 570)
    list = Keyword.get(opts, :list, [%{"id" => 7, "root_task_id" => 700}])
    fail_comment_post = Keyword.get(opts, :fail_comment_post, false)
    reply_to = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(
        conn,
        pressure,
        fn conn ->
          case {conn.method, conn.request_path} do
            {"GET", "/api/v1/initiatives"} ->
              Req.Test.json(conn, %{"data" => list})

            # The open-only approval consult (m03.04 2.8.8): the newest row
            # for the batch's hash — 404 when nothing is parked.
            {"GET", "/api/v1/import_approvals/" <> hash} ->
              send(reply_to, {:approval_get, hash})

              case Keyword.get(opts, :approval_status) do
                nil ->
                  conn
                  |> Plug.Conn.put_status(404)
                  |> Req.Test.json(%{"error" => %{"status" => 404, "code" => "not_found"}})

                status ->
                  Req.Test.json(conn, %{
                    "data" =>
                      %{"payload_hash" => hash, "status" => status}
                      |> Map.put("decision_reason", Keyword.get(opts, :approval_reason))
                  })
              end

            # The park POST — idempotent server-side; answers pending plus
            # the operator-facing approve URL.
            {"POST", "/api/v1/import_approvals"} ->
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              decoded = Jason.decode!(body)
              send(reply_to, {:approval_post, decoded})

              Req.Test.json(conn, %{
                "data" =>
                  Map.merge(decoded, %{
                    "status" => "pending",
                    "url" => "http://app.test/account#import-approvals"
                  })
              })

            # The declaration record (m03.04 2.8.10) — Initiative-homed,
            # idempotent server-side.
            {"POST", "/api/v1/import_declarations"} ->
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              decoded = Jason.decode!(body)
              send(reply_to, {:declaration_post, decoded})
              Req.Test.json(conn, %{"data" => decoded})

            {"GET", "/api/v1/tasks/" <> _} ->
              send(reply_to, {:task_read, conn.request_path})
              parent_id = Keyword.get(opts, :parent_id, 42)
              parent_initiative = Keyword.get(opts, :parent_initiative, 7)

              Req.Test.json(conn, %{
                "data" => %{"id" => parent_id, "initiative_id" => parent_initiative}
              })

            {"POST", "/api/v1/operations"} ->
              {:ok, body, conn} = Plug.Conn.read_body(conn)
              decoded = Jason.decode!(body)
              send(reply_to, {:operations_post, decoded})

              comment_post? =
                match?([%{"type" => "comment"}], decoded["operations"])

              cond do
                comment_post? and fail_comment_post ->
                  conn
                  |> Plug.Conn.put_status(500)
                  |> Req.Test.json(%{"error" => %{"status" => 500, "code" => "boom"}})

                Enum.any?(decoded["operations"] || [], fn op ->
                  op["type"] == "initiative" and op["op"] == "add" and op["lid"] == "i"
                end) ->
                  Req.Test.json(conn, %{
                    "results" => [
                      %{
                        "index" => 0,
                        "lid" => "i",
                        "status" => "ok",
                        "data" => %{
                          "id" => created_id,
                          "type" => "initiative",
                          "root_task_id" => created_root
                        }
                      }
                    ]
                  })

                true ->
                  Req.Test.json(conn, %{"results" => []})
              end
          end
        end,
        extra
      )
    end)
  end

  defp decode_json_content(response) do
    protocol = Response.to_protocol(response)
    assert [%{"type" => "text", "text" => text} | rest] = protocol["content"]
    {protocol, Jason.decode!(text), rest}
  end

  defp execute_ok(params) when is_map(params) do
    assert {:reply, response, @frame} = ApplyOperations.execute(params, @frame)
    {protocol, decoded, rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    rest
  end

  defp execute_ok(ops), do: execute_ok(%{operations: ops})

  defp execute_refused(params) do
    assert {:reply, response, @frame} = ApplyOperations.execute(params, @frame)
    {protocol, decoded, _rest} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    decoded
  end

  # The record comment: the second operations POST, one comment op on the
  # root. Returns its body text for content assertions. A readback-carrying
  # record keeps the readback prefix; a declaration-led record (no prose)
  # opens as the accepted declaration.
  defp assert_record_posted(root_task_id, prefix \\ "Import record — readback as applied:") do
    assert_received {:operations_post, %{"operations" => [_ | _]}}

    assert_received {:operations_post,
                     %{
                       "operations" => [
                         %{
                           "op" => "add",
                           "type" => "comment",
                           "data" => %{"task_id" => ^root_task_id, "body" => body}
                         }
                       ]
                     }}

    assert body =~ prefix
    body
  end

  # The whole-import declaration matching new_initiative_batch/1 (first task
  # arriving done) or all_open_bootstrap/1 (`done: 0`).
  defp declared(params, total, done \\ 1) do
    Map.merge(params, %{
      declared_sources: [%{"path" => "docs/PLAN.md", "checkbox_lines" => total}],
      declared_total: total,
      declared_completed: done,
      declared_ordering: "none"
    })
  end

  test "an aged Initiative's batch at the threshold applies straight through, no record demanded" do
    stub_apply()

    execute_ok(existing_initiative_batch(@threshold, 7))

    # One POST — the batch; no record comment rode along.
    assert_received {:operations_post, _batch}
    refute_received {:operations_post, _}
  end

  test "an import-shaped batch without a readback is refused with the teach" do
    stub_apply()

    ops = existing_initiative_batch(@threshold + 1, 7)
    decoded = execute_refused(%{operations: ops})

    assert decoded["gate"] == "import_readback"
    assert decoded["message"] =~ "#{@threshold + 1} tasks"
    assert decoded["message"] =~ "no operator step is needed"
    assert decoded["message"] =~ "provenance comment on the target Initiative's root task"
    # The recovery is the readback, not a smaller batch (m03.04 2.5.5).
    assert decoded["message"] =~ "settling the session"
    refute decoded["message"] =~ "#{ImportGate.ramp_threshold()} cumulative"

    # Refused unapplied — nothing was posted.
    refute_received {:operations_post, _}
  end

  test "an import-shaped batch with a readback applies immediately; the record lands on the root" do
    stub_apply()

    ops = existing_initiative_batch(@threshold + 1, 7)

    rest =
      execute_ok(%{
        operations: ops,
        readback: "Importing PLAN.md as #{@threshold + 1} tasks.",
        assumptions: ["Assumed whole-plan scope."],
        settled: ["Operator asked for milestone depth."]
      })

    body = assert_record_posted(700)
    assert body =~ "Importing PLAN.md as #{@threshold + 1} tasks."
    assert body =~ "Settled (operator-instructed):\n- Operator asked for milestone depth."
    assert body =~ "Assumptions:\n- Assumed whole-plan scope."
    refute body =~ "Operator-confirmed in chat."

    assert Enum.any?(rest, &(&1["text"] =~ "posted as a provenance comment"))
  end

  test "one record settles the Initiative for the session — later chunks flow without re-asking" do
    start_gate_state()
    stub_apply()

    ops = existing_initiative_batch(@threshold + 1, 7)
    execute_ok(%{operations: ops, readback: "Importing the plan."})
    assert_record_posted(700)

    # The window far over the line — but this session's record already exists,
    # so the chunk flows and posts no second record.
    stub_apply(pressure: 200)
    execute_ok(existing_initiative_batch(15, 7))
    assert_received {:operations_post, _batch}
    refute_received {:operations_post, _}
  end

  test "a record under the lid carries to the created id — later chunks never re-ask" do
    start_gate_state()
    stub_apply()

    # A bootstrap is a FIRST import (2.8.10), so the batch carries its
    # declaration; the volunteered readback rides the same record.
    ops = new_initiative_batch(@threshold + 1)

    execute_ok(
      declared(%{operations: ops, readback: "Bootstrapping the import."}, @threshold + 1)
    )

    # The record posted to the created Initiative's root, echoed in the
    # apply response — no list read needed for an in-batch target; the
    # accepted declaration lands Initiative-homed under the created id.
    body = assert_record_posted(570)
    assert body =~ "Bootstrapping the import."
    assert_received {:declaration_post, %{"initiative_id" => 57, "source_total" => _}}

    # Chunk 2 references the real id past every bound: the record followed
    # the Initiative to its real id.
    stub_apply(pressure: 200)
    execute_ok(existing_initiative_batch(15, 57))
    assert_received {:operations_post, _batch}
    refute_received {:operations_post, _}
  end

  test "cumulative pressure across chunks demands the readback record" do
    start_gate_state()
    stub_apply()

    # Chunk 1: 20 adds — coherent, under every bound; applies silently.
    execute_ok(existing_initiative_batch(20, 7))
    assert_received {:operations_post, _batch}

    # The DB window now reports the ramp nearly ridden out — one more
    # coherent chunk crosses the RAMP bound and needs the record.
    stub_apply(pressure: 120)
    decoded = execute_refused(%{operations: existing_initiative_batch(15, 7)})
    assert decoded["gate"] == "import_readback"
    assert decoded["message"] =~ "15 tasks"
    assert decoded["message"] =~ "135 this session"
    refute_received {:operations_post, _}
  end

  test "a fresh Initiative's big first batch is interviewed, not floored — declared, it flows" do
    # Bootstrap with 20 adds: under the ramp, no readback demanded — but a
    # FIRST import answers the declaration (2.8.10), which posts as its
    # record.
    stub_apply()
    execute_ok(declared(%{operations: new_initiative_batch(20)}, 20))
    assert_record_posted(570, "Import record — declaration as accepted:")

    # Iteration 3's exact repro, replayed under item 36: the Initiative was
    # created moments ago (task_count says so) and the scaffold arrives by
    # real id — it flows like any aged Initiative's (this response carries
    # no live_count, so first-import detection stays fail-open).
    created = DateTime.utc_now() |> DateTime.add(-2, :minute) |> DateTime.to_iso8601()
    stub_apply(pressure: 2, task_count_extra: %{"initiative_created_at" => created})
    execute_ok(existing_initiative_batch(12, 57))
    assert_received {:operations_post, _batch}
    refute_received {:operations_post, _}
  end

  test "a mirror batch refuses and parks for the operator's approval (m03.04 2.8.5.3)" do
    stub_apply()
    decoded = execute_refused(%{operations: mirror_batch(7)})

    assert decoded["gate"] == "batch_shape"
    assert decoded["message"] =~ "file-mirror import"
    assert decoded["message"] =~ "they approve this import in the app"
    # One override mechanism now — the agent can no longer attest.
    refute decoded["message"] =~ "operator_confirmed"
    # Parked under this batch's own hash, approve URL handed back.
    assert_received {:approval_post, %{"payload_hash" => _}}
    assert decoded["approve_url"] == "http://app.test/account#import-approvals"
    refute_received {:operations_post, _}
  end

  test "the operator's in-app approval overrides the refusal and stamps the record" do
    stub_apply(approval_status: "approved")

    rest =
      execute_ok(%{
        operations: mirror_batch(7),
        readback: "One task per source file, as the operator asked."
      })

    body = assert_record_posted(700)
    assert body =~ "One task per source file, as the operator asked."
    assert body =~ "Operator-approved in the app."
    # The server's facts print under the claim — a rosy readback can't hide
    # the shape.
    assert body =~ "Server-computed shape facts:"
    assert body =~ "12 of 12 new task titles look like file paths/names."

    # Approved means approved — nothing re-parks.
    refute_received {:approval_post, _}
    assert Enum.any?(rest, &(&1["text"] =~ "posted as a provenance comment"))
  end

  test "an approved shape override without a readback is refused asking for the record" do
    stub_apply(approval_status: "approved")
    decoded = execute_refused(%{operations: mirror_batch(7)})

    assert decoded["gate"] == "import_readback"
    assert decoded["message"] =~ "approved this import in the app"
    assert decoded["message"] =~ "stamped operator-approved"
    refute_received {:operations_post, _}
  end

  test "a dismissed shape refusal latches for that payload, and never re-parks" do
    stub_apply(approval_status: "dismissed")
    decoded = execute_refused(%{operations: mirror_batch(7)})

    assert decoded["gate"] == "batch_shape"
    assert decoded["message"] =~ "rejected this exact import in the app"
    refute_received {:approval_post, _}
    refute_received {:operations_post, _}
  end

  test "a flattened first import is refused end to end (m03.04 2.8.11)" do
    stub_apply()

    decoded =
      execute_refused(
        %{operations: new_initiative_batch(12)}
        |> Map.merge(%{
          declared_sources: [%{"path" => "docs/PLAN.md", "checkbox_lines" => 340}],
          declared_total: 12,
          declared_completed: 9,
          declared_ordering: "outline"
        })
      )

    assert decoded["message"] =~ "340 checkbox lines"
    assert decoded["message"] =~ "only 12 items"
    refute_received {:operations_post, _}
    refute_received {:declaration_post, _}
  end

  test "the accepted declaration records the documents it was read from (2.8.11)" do
    stub_apply()

    execute_ok(declared(%{operations: new_initiative_batch(12)}, 12))

    body = assert_record_posted(570, "Import record — declaration as accepted:")
    assert body =~ "Documents read: docs/PLAN.md (12 checkbox lines)"
  end

  test "the park carries the batch's deepest-branch snapshot (m03.04 3.1.9.2)" do
    stub_apply()
    execute_refused(%{operations: mirror_batch(7)})

    assert_received {:approval_post, posted}
    assert %{"nodes" => [_ | _] = nodes} = posted["sample"]
    assert Enum.all?(nodes, &Map.has_key?(&1, "depth"))
    assert Enum.all?(nodes, &Map.has_key?(&1, "title"))
  end

  test "a rejection's words reach the agent, quoted and attributed (m03.04 3.1.9.2)" do
    stub_apply(
      approval_status: "dismissed",
      approval_reason: "These are my milestones, not files. Import the checklists under them."
    )

    decoded = execute_refused(%{operations: mirror_batch(7)})

    assert decoded["gate"] == "batch_shape"
    assert decoded["message"] =~ "The operator rejected this exact import"
    assert decoded["message"] =~ "Import the checklists under them."
    refute decoded["message"] =~ "without saying why"
    refute_received {:operations_post, _}
  end

  test "the account's dormant ceremony (2.8.9) lets a shape refusal through" do
    stub_apply(approval_status: "skipped")

    execute_ok(%{
      operations: mirror_batch(7),
      readback: "One task per source file — this account runs the skill."
    })

    assert_received {:operations_post, _batch}
    refute_received {:approval_post, _}
  end

  test "a sub-scale checklist batch is refused with the subtasks-or-approve recovery words" do
    stub_apply()
    decoded = execute_refused(%{operations: checklist_batch(7)})

    assert decoded["gate"] == "batch_shape"
    assert decoded["message"] =~ "2 markdown-checkbox lines sit inside 1 new task descriptions"
    assert decoded["message"] =~ "Import them as subtasks instead"
    assert decoded["message"] =~ "they approve this import in the app"
    refute decoded["message"] =~ "operator_confirmed"
    refute_received {:operations_post, _}

    # The operator's keep-as-prose choice applies through the same approval,
    # with the checkbox fact in the record.
    stub_apply(approval_status: "approved")

    execute_ok(%{
      operations: checklist_batch(7),
      readback: "Keeping the setup checklist as description prose, as asked."
    })

    body = assert_record_posted(700)
    assert body =~ "2 markdown-checkbox lines sit inside 1 new descriptions."
    assert body =~ "Operator-approved in the app."
  end

  test "the kill switch disarms the shape pass with the classifier" do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    stub_apply()

    execute_ok(mirror_batch(7))
    assert_received {:operations_post, _batch}
    refute_received {:operations_post, _}
  end

  test "a failed record post leaves the batch applied and hands the agent the fallback" do
    stub_apply(fail_comment_post: true)

    ops = existing_initiative_batch(@threshold + 1, 7)
    rest = execute_ok(%{operations: ops, readback: "Importing the plan."})

    assert_received {:operations_post, _batch}
    assert_received {:operations_post, %{"operations" => [%{"type" => "comment"}]}}
    assert Enum.any?(rest, &(&1["text"] =~ "could NOT be posted"))
    assert Enum.any?(rest, &(&1["text"] =~ "root_task_id"))
  end

  describe "the first-import interview (m03.04 2.8.10)" do
    # all_open_bootstrap(20): an in-batch target — live tree 0, cumulative
    # 20 past the floor, no recorded declaration. First-import scope.

    test "a first import without a declaration is refused with the demand — no park, nothing applied" do
      stub_apply()

      decoded = execute_refused(%{operations: all_open_bootstrap(20)})

      assert decoded["gate"] == "import_declaration"
      assert decoded["message"] =~ "First-import declaration required"
      assert decoded["message"] =~ "`declared_total`"
      assert decoded["message"] =~ "`declared_completed`"
      assert decoded["message"] =~ "`declared_exclusions`"
      assert decoded["message"] =~ "`declared_ordering`"
      assert decoded["message"] =~ "no operator step is needed"

      # The demand consulted the off-switch by hash, parked nothing.
      assert_received {:approval_get, _hash}
      refute_received {:approval_post, _}
      refute_received {:operations_post, _}
    end

    test "operator_confirmed doesn't answer the interview — the declaration fields do" do
      stub_apply()

      decoded =
        execute_refused(%{
          operations: all_open_bootstrap(20),
          operator_confirmed: true,
          readback: "Open items only."
        })

      assert decoded["gate"] == "import_declaration"
      refute_received {:operations_post, _}
    end

    test "a consistent fresh plan — declared 0 complete, 0 done adds — flows with NO park" do
      stub_apply()

      rest = execute_ok(declared(%{operations: all_open_bootstrap(20)}, 20, 0))

      # No approval ceremony at all; the open-only guidance still rides.
      refute_received {:approval_get, _}
      refute_received {:approval_post, _}
      assert Enum.any?(rest, &(&1["text"] =~ "All 20 imported tasks arrived open."))

      # The declaration IS the record: posted verbatim on the created root,
      # beside the open-only shape fact, and recorded Initiative-homed.
      body = assert_record_posted(570, "Import record — declaration as accepted:")
      assert body =~ "Import declaration (agent-stated, server-checked):"
      assert body =~ "- Source: 20 items, 0 complete."
      assert body =~ "- Exclusions: none declared."
      assert body =~ "- Ordering: none."
      assert body =~ "All 20 new tasks arrive open — none marked done."

      assert_received {:declaration_post,
                       %{
                         "initiative_id" => 57,
                         "source_total" => 20,
                         "source_completed" => 0,
                         "excluded_count" => 0
                       }}
    end

    test "each mismatch direction refuses naming the numbers" do
      stub_apply()

      # Over-delivery: cumulative adds past the declared importable total.
      decoded = execute_refused(declared(%{operations: all_open_bootstrap(20)}, 15, 0))
      assert decoded["gate"] == "import_declaration"
      assert decoded["message"] =~ "cumulative adds reach 20"
      assert decoded["message"] =~ "importable total of 15"

      # Done overshoot: more `done` arrivals than the source declares complete.
      decoded = execute_refused(declared(%{operations: new_initiative_batch(20)}, 20, 0))
      assert decoded["message"] =~ "1 tasks arrive `done` against 0 declared complete"

      # Undeclared narrowing: the import completes open-only against a
      # declared-complete source with no exclusions to absorb it.
      decoded = execute_refused(declared(%{operations: all_open_bootstrap(20)}, 20, 5))
      assert decoded["message"] =~ "0 arrived `done`"
      assert decoded["message"] =~ "5 missing completed items"

      refute_received {:operations_post, _}
      refute_received {:approval_post, _}
    end

    test "a declared exclusion of completed work parks for the operator (2.8.8 reused)" do
      stub_apply()

      params =
        declared(%{operations: all_open_bootstrap(15)}, 20, 5)
        |> Map.put(:declared_exclusions, [
          %{"count" => 5, "reason" => "completed items — operator asked for open work only"}
        ])

      decoded = execute_refused(params)

      assert decoded["gate"] == "import_declaration"
      assert decoded["message"] =~ "Import parked"
      assert decoded["message"] =~ "the operator's call"
      assert decoded["message"] =~ "re-send this SAME batch unchanged"
      refute decoded["message"] =~ "operator_confirmed"
      assert decoded["approve_url"] == "http://app.test/account#import-approvals"

      # Consulted, then parked — with the batch's facts, never the payload.
      assert_received {:approval_get, hash}

      assert_received {:approval_post,
                       %{
                         "payload_hash" => ^hash,
                         "task_count" => 15,
                         "initiative_name" => "Import"
                       }}

      refute_received {:operations_post, _}

      # A retry against the standing pending park re-parks idempotently
      # (the server returns the same row) and refuses the same way.
      stub_apply(approval_status: "pending")
      decoded = execute_refused(params)
      assert decoded["message"] =~ "Import parked"
      assert_received {:approval_get, ^hash}
      assert_received {:approval_post, %{"payload_hash" => ^hash}}
      refute_received {:operations_post, _}
    end

    test "the operator's approval lets the SAME batch flow; the record stamps the click" do
      stub_apply(approval_status: "approved")

      params =
        declared(%{operations: all_open_bootstrap(15)}, 20, 5)
        |> Map.put(:declared_exclusions, [
          %{"count" => 5, "reason" => "completed items — operator asked for open work only"}
        ])

      execute_ok(params)

      assert_received {:approval_get, _}
      refute_received {:approval_post, _}

      body = assert_record_posted(570, "Import record — declaration as accepted:")
      assert body =~ "Operator-approved in the app."

      assert body =~
               "- Exclusions (5 items): 5 × completed items — operator asked for open work only."

      assert body =~ "All 15 new tasks arrive open — none marked done."

      assert_received {:declaration_post, %{"initiative_id" => 57, "excluded_count" => 5}}
    end

    test "a dismissed park latches: the same payload keeps refusing as declined, no re-park" do
      stub_apply(approval_status: "dismissed")

      params =
        declared(%{operations: all_open_bootstrap(15)}, 20, 5)
        |> Map.put(:declared_exclusions, [%{"count" => 5, "reason" => "completed items"}])

      decoded = execute_refused(params)

      assert decoded["gate"] == "import_declaration"
      assert decoded["message"] =~ "operator rejected"
      assert decoded["message"] =~ "talk to the operator"
      assert_received {:approval_get, _}
      refute_received {:approval_post, _}
      refute_received {:operations_post, _}
    end

    test "a grown tree keeps today's behavior — no declaration demanded" do
      stub_apply(task_count_extra: %{"live_count" => 40})

      execute_ok(existing_initiative_batch(12, 7))

      assert_received {:operations_post, _batch}
      refute_received {:approval_get, _}
      refute_received {:operations_post, _}
    end

    test "chunked continuation checks the recorded declaration — consistent flows, irreconcilable refuses" do
      recorded = %{
        "source_total" => 20,
        "source_completed" => 0,
        "excluded_count" => 0,
        "ordering" => "none"
      }

      # 8 adds already in the window; this 12-add chunk lands exactly on the
      # declared total — consistent, applies with no interview noise.
      stub_apply(
        pressure: 8,
        task_count_extra: %{
          "live_count" => 8,
          "done_count" => 0,
          "import_declaration" => recorded
        }
      )

      execute_ok(existing_initiative_batch(12, 7))
      assert_received {:operations_post, _batch}
      refute_received {:operations_post, _}

      # The under-floor dribble meets the same arithmetic: 5 more adds push
      # cumulative to 25 against 20 declared — irreconcilable, refused.
      stub_apply(
        pressure: 20,
        task_count_extra: %{
          "live_count" => 20,
          "done_count" => 0,
          "import_declaration" => recorded
        }
      )

      decoded = execute_refused(%{operations: existing_initiative_batch(5, 7)})
      assert decoded["gate"] == "import_declaration"
      assert decoded["message"] =~ "cumulative adds reach 25"
      assert decoded["message"] =~ "importable total of 20"
      refute_received {:operations_post, _}
    end

    test "the account off-switch skips the demand — the batch applies, guidance still rides" do
      # The operator's account-level opt-out (m03.04 2.8.9): the demand's
      # consult answers `skipped`, the interview goes dormant, and the SAME
      # undeclared bootstrap applies as a plain pass. The stop is silenced,
      # never the telemetry — the open-only guidance still ends the response.
      stub_apply(approval_status: "skipped")

      rest = execute_ok(%{operations: all_open_bootstrap(20)})

      assert_received {:approval_get, _hash}
      refute_received {:approval_post, _}
      assert_received {:operations_post, _batch}
      # No declaration accepted, sub-gate — no record comment posted.
      refute_received {:operations_post, _}

      assert Enum.any?(rest, &(&1["text"] =~ "All 20 imported tasks arrived open."))
    end

    test "the off-switch with a declared exclusion: no park, the declaration still records" do
      stub_apply(approval_status: "skipped")

      params =
        declared(%{operations: all_open_bootstrap(15)}, 20, 5)
        |> Map.put(:declared_exclusions, [%{"count" => 5, "reason" => "completed items"}])

      execute_ok(params)

      assert_received {:approval_get, _}
      refute_received {:approval_post, _}

      # The ceremony was dormant — no click, so no approval stamp — but the
      # declaration still lands as the record, facts riding.
      body = assert_record_posted(570, "Import record — declaration as accepted:")
      refute body =~ "Operator-approved in the app."
      assert body =~ "- Exclusions (5 items): 5 × completed items."
      assert_received {:declaration_post, %{"initiative_id" => 57}}
    end
  end

  describe "parent-anchored adds (m03.04 2.8.1)" do
    test "an over-threshold parent-anchored batch demands the record — no dodging via parent_id" do
      stub_apply()

      decoded = execute_refused(%{operations: parent_anchored_batch(@threshold + 1, 42)})
      assert decoded["gate"] == "import_readback"

      # One read per unique parent, deduped across the batch.
      assert_received {:task_read, "/api/v1/tasks/42"}
      refute_received {:task_read, _}
      refute_received {:operations_post, _}
    end

    test "with a readback the record carries the target's index style" do
      stub_apply(task_count_extra: %{"initiative_index_style" => "outline"})

      execute_ok(%{
        operations: parent_anchored_batch(@threshold + 1, 42),
        readback: "Growing the M7 subtree from the worklist."
      })

      body = assert_record_posted(700)
      assert body =~ "Target Initiative index_style: outline."
    end

    test "a below-threshold parent-anchored batch applies straight through, one read per unique parent" do
      stub_apply()

      execute_ok(parent_anchored_batch(5, 42))

      assert_received {:task_read, "/api/v1/tasks/42"}
      refute_received {:task_read, _}
      assert_received {:operations_post, _batch}
      refute_received {:operations_post, _}
    end

    test "an unresolvable parent (404 read) stays dropped — the classifier passes, the apply speaks" do
      reply_to = self()

      Req.Test.stub(DoitMcp.Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/tasks/" <> _} ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"error" => %{"status" => 404, "code" => "not_found"}})

          {"POST", "/api/v1/operations"} ->
            {:ok, _body, conn} = Plug.Conn.read_body(conn)
            send(reply_to, :applied)
            Req.Test.json(conn, %{"results" => []})
        end
      end)

      execute_ok(parent_anchored_batch(@threshold + 1, 42))
      assert_received :applied
    end
  end
end
