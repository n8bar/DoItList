defmodule DoitMcp.ApplyOperationsGateTest do
  @moduledoc """
  The no-stop import model (m03.04 item 36): an import-shaped batch applies
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

  defp new_initiative_batch(task_count) do
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
  # root. Returns its body text for content assertions.
  defp assert_record_posted(root_task_id) do
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

    assert body =~ "Import record — readback as applied:"
    body
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
    # The over-ramp recovery words: chunk (m03.04 item 36.2).
    assert decoded["message"] =~ "at most #{ImportGate.threshold()} adds"
    assert decoded["message"] =~ "#{ImportGate.ramp_threshold()} cumulative"

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

    assert Enum.any?(rest, &(&1["text"] =~ "recorded as a provenance comment"))
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

    ops = new_initiative_batch(@threshold + 1)
    execute_ok(%{operations: ops, readback: "Bootstrapping the import."})

    # The record posted to the created Initiative's root, echoed in the
    # apply response — no list read needed for an in-batch target.
    body = assert_record_posted(570)
    assert body =~ "Bootstrapping the import."

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

  test "a fresh Initiative's big first batch flows — the fresh floor is retired" do
    # Bootstrap with 20 adds: past the retired floor of 8, under the ramp —
    # applies with no readback and no record demanded.
    stub_apply()
    execute_ok(new_initiative_batch(20))
    assert_received {:operations_post, _batch}
    refute_received {:operations_post, _}

    # Iteration 3's exact repro, replayed under item 36: the Initiative was
    # created moments ago (task_count says so) and the scaffold arrives by
    # real id — it flows like any aged Initiative's.
    created = DateTime.utc_now() |> DateTime.add(-2, :minute) |> DateTime.to_iso8601()
    stub_apply(pressure: 2, task_count_extra: %{"initiative_created_at" => created})
    execute_ok(existing_initiative_batch(12, 57))
    assert_received {:operations_post, _batch}
    refute_received {:operations_post, _}
  end

  test "a mirror batch refuses, teaching the operator_confirmed re-call" do
    decoded = execute_refused(%{operations: mirror_batch(7)})

    assert decoded["gate"] == "batch_shape"
    assert decoded["message"] =~ "file-mirror import"
    assert decoded["message"] =~ "`operator_confirmed: true` plus `readback`"
    refute_received {:operations_post, _}
  end

  test "operator_confirmed overrides the refusal and stamps the record" do
    stub_apply()

    rest =
      execute_ok(%{
        operations: mirror_batch(7),
        operator_confirmed: true,
        readback: "One task per source file, as the operator asked."
      })

    body = assert_record_posted(700)
    assert body =~ "One task per source file, as the operator asked."
    assert body =~ "Operator-confirmed in chat."
    # The server's facts print under the claim — a rosy readback can't hide
    # the shape.
    assert body =~ "Server-computed shape facts:"
    assert body =~ "12 of 12 new task titles look like file paths/names."

    assert Enum.any?(rest, &(&1["text"] =~ "recorded as a provenance comment"))
  end

  test "operator_confirmed without a readback is refused asking for the record" do
    stub_apply()
    decoded = execute_refused(%{operations: mirror_batch(7), operator_confirmed: true})

    assert decoded["gate"] == "import_readback"
    assert decoded["message"] =~ "attestation"
    assert decoded["message"] =~ "stamped operator-confirmed"
    refute_received {:operations_post, _}
  end

  test "a sub-scale checklist batch is refused with the subtasks-or-ask recovery words" do
    decoded = execute_refused(%{operations: checklist_batch(7)})

    assert decoded["gate"] == "batch_shape"
    assert decoded["message"] =~ "2 markdown-checkbox lines sit inside 1 new task descriptions"
    assert decoded["message"] =~ "Import them as subtasks instead"
    assert decoded["message"] =~ "ask the operator in chat"
    assert decoded["message"] =~ "`operator_confirmed: true`"
    refute_received {:operations_post, _}

    # The operator's keep-as-prose choice applies via the override, with the
    # checkbox fact in the record.
    stub_apply()

    execute_ok(%{
      operations: checklist_batch(7),
      operator_confirmed: true,
      readback: "Keeping the setup checklist as description prose, as asked."
    })

    body = assert_record_posted(700)
    assert body =~ "2 markdown-checkbox lines sit inside 1 new descriptions."
    assert body =~ "Operator-confirmed in chat."
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

  describe "parent-anchored adds (m03.04 item 2.18)" do
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
