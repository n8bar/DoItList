defmodule DoitMcp.ApplyOperationsGateTest.FakeSession do
  @moduledoc """
  Stands in for the Anubis session process in gate tests: holds
  `client_capabilities` where `DoitMcp.Elicitation` reads them
  (`:sys.get_state/1`) and forwards `{:send_elicitation_request, ...}` info
  messages to the test process so it can play the operator.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    {:ok, %{client_capabilities: opts[:capabilities], forward_to: opts[:forward_to]}}
  end

  @impl true
  def handle_info({:send_elicitation_request, _params, _schema, _timeout} = msg, state) do
    send(state.forward_to, msg)
    {:noreply, state}
  end
end

defmodule DoitMcp.ApplyOperationsGateTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.ApplyOperationsGateTest.FakeSession
  alias DoitMcp.{Elicitation, ImportGate}
  alias DoitMcp.Tools.ApplyOperations

  @threshold ImportGate.threshold()
  @frame %{test: true}

  # The gate ships armed (DOITLIST_IMPORT_GATE=off opts out); pin it on here
  # so these behavior tests stay deterministic against the container's
  # ambient environment.
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  # The cumulative describe starts one; everything else runs counter-less
  # (DoitMcp.ImportGate.Counter degrades to zero/no-op), i.e. single-batch
  # semantics.
  defp start_counter do
    name = :"#{__MODULE__}.Counter"
    start_supervised!({DoitMcp.ImportGate.Counter, name: name})

    previous = Application.fetch_env(:doit_mcp, :import_gate_counter)
    Application.put_env(:doit_mcp, :import_gate_counter, name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_counter, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_counter)
      end
    end)
  end

  defp fake_session(capabilities) do
    name = :"#{__MODULE__}.FakeSession"
    start_supervised!({FakeSession, name: name, capabilities: capabilities, forward_to: self()})

    previous = Application.fetch_env(:doit_mcp, :elicitation_session_name)
    Application.put_env(:doit_mcp, :elicitation_session_name, name)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :elicitation_session_name, value)
        :error -> Application.delete_env(:doit_mcp, :elicitation_session_name)
      end
    end)
  end

  defp elicitation_capable, do: fake_session(%{"elicitation" => %{}})

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

  # Serves GET /initiatives/:id/task_count — the DB-window pressure read
  # (m03.04 3.1 iteration 2) — ahead of a stub's other clauses. `extra`
  # merges further task_count facts (e.g. initiative_index_style); the
  # count-only default models a response WITHOUT the style key, so tests on
  # it exercise the confirm's fail-open no-line lane.
  defp with_pressure(conn, pressure, fallback, extra \\ %{}) do
    if conn.method == "GET" and String.ends_with?(conn.request_path, "/task_count") do
      Req.Test.json(conn, %{"data" => Map.merge(%{"count" => pressure}, extra)})
    else
      fallback.(conn)
    end
  end

  # GET /api/v1/tasks/:id resolves the anchor parent to its Initiative (and
  # reports each read to the test process, so dedup is assertable); GET
  # /api/v1/initiatives/:id serves the target knobless; POST applies.
  defp stub_parent_resolve_and_apply(parent_id, initiative_id, pressure \\ 0, extra \\ %{}) do
    reply_to = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(
        conn,
        pressure,
        fn conn ->
          case {conn.method, conn.request_path} do
            {"GET", "/api/v1/tasks/" <> _} ->
              send(reply_to, {:task_read, conn.request_path})

              Req.Test.json(conn, %{
                "data" => %{"id" => parent_id, "initiative_id" => initiative_id}
              })

            # AI-KNOBS-PARKED (m03.04): unreached — the gate's knobs fetch is
            # parked; a revived fetch hits it again.
            {"GET", "/api/v1/initiatives/" <> _} ->
              Req.Test.json(conn, %{"data" => %{"id" => initiative_id, "ai_knobs" => nil}})

            {"POST", "/api/v1/operations"} ->
              Req.Test.json(conn, %{"results" => []})
          end
        end,
        extra
      )
    end)
  end

  defp stub_apply_ok(pressure \\ 0) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(conn, pressure, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/api/v1/operations"
        Req.Test.json(conn, %{"results" => []})
      end)
    end)
  end

  defp decode_json_content(response) do
    protocol = Response.to_protocol(response)
    assert [%{"type" => "text", "text" => text} | rest] = protocol["content"]
    {protocol, Jason.decode!(text), rest}
  end

  defp stub_get_and_apply(knobs, pressure \\ 0) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(conn, pressure, fn conn ->
        case {conn.method, conn.request_path} do
          # AI-KNOBS-PARKED (m03.04): unreached — the gate's knobs fetch is
          # parked; a revived fetch hits it (and the knobs arg matters) again.
          {"GET", "/api/v1/initiatives/7"} ->
            Req.Test.json(conn, %{"data" => %{"id" => 7, "ai_knobs" => knobs}})

          {"POST", "/api/v1/operations"} ->
            Req.Test.json(conn, %{"results" => []})
        end
      end)
    end)
  end

  # POST echoes the created Initiative's lid → real id (the wire shape for
  # creates); GET serves its ai_knobs (AI-KNOBS-PARKED: unreached while the
  # gate's knobs fetch is parked; a revived fetch hits it again).
  defp stub_create_echo_and_get(initiative_id, knobs, pressure \\ 0) do
    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(conn, pressure, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/v1/operations"} ->
            Req.Test.json(conn, %{
              "results" => [
                %{
                  "index" => 0,
                  "lid" => "i",
                  "status" => "ok",
                  "data" => %{"id" => initiative_id, "type" => "initiative"}
                }
              ]
            })

          {"GET", "/api/v1/initiatives/" <> _} ->
            Req.Test.json(conn, %{"data" => %{"id" => initiative_id, "ai_knobs" => knobs}})
        end
      end)
    end)
  end

  # Like stub_create_echo_and_get, but task_count also carries a FRESH
  # initiative_created_at (m03.04 3.1 iteration 3) — the Initiative is still
  # inside its freshness window, so fresh?/1 reads true over HTTP.
  defp stub_fresh_create_echo_and_get(initiative_id, pressure \\ 0) do
    created = DateTime.utc_now() |> DateTime.add(-2, :minute) |> DateTime.to_iso8601()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", path} ->
          if String.ends_with?(path, "/task_count") do
            Req.Test.json(conn, %{
              "data" => %{"count" => pressure, "initiative_created_at" => created}
            })
          else
            # AI-KNOBS-PARKED (m03.04): unreached — the gate's knobs fetch is
            # parked; a revived fetch hits it again.
            Req.Test.json(conn, %{"data" => %{"id" => initiative_id, "ai_knobs" => nil}})
          end

        {"POST", "/api/v1/operations"} ->
          Req.Test.json(conn, %{
            "results" => [
              %{
                "index" => 0,
                "lid" => "i",
                "status" => "ok",
                "data" => %{"id" => initiative_id, "type" => "initiative"}
              }
            ]
          })
      end
    end)
  end

  defp execute_ok(ops) do
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {protocol, decoded, _rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
  end

  test "an aged Initiative's batch at the threshold applies straight through, no elicitation" do
    elicitation_capable()
    # The count-only task_count stub models an Initiative older than the
    # window: no initiative_created_at → not fresh (fail-open) → old bounds.
    stub_apply_ok()

    ops = existing_initiative_batch(@threshold, 7)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "a client without the elicitation capability skips the gate entirely" do
    fake_session(%{"sampling" => %{}})
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    refute Elicitation.client_supports_elicitation?()

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {_, decoded, _} = decode_json_content(response)
    assert decoded["ok"] == true
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "gated batch without readback is rejected unapplied, telling the agent what to supply" do
    elicitation_capable()

    ops = new_initiative_batch(@threshold + 1)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    protocol = Response.to_protocol(response)
    assert protocol["isError"] == true
    assert [%{"type" => "text", "text" => text}] = protocol["content"]
    assert text =~ "readback"
    assert text =~ "assumptions"
    assert text =~ "settled"
    assert text =~ "#{@threshold + 1} tasks"
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "operator confirm applies the batch and appends the confirm note" do
    elicitation_capable()
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    readback = "Importing PLAN.md as 31 tasks under one new Initiative, two levels deep."
    assumptions = ["Depth taken from markdown heading levels", "Struck-through items skipped"]

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: ops, readback: readback, assumptions: assumptions},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, params, schema, timeout}, 2_000

    # Message: readback verbatim, the server's facts (the in-batch
    # Initiative's index_style — always notable), assumptions as a list,
    # then the decision line naming all three choices. No `settled` passed →
    # no Settled block; an in-batch target → no target-style read.
    assert params["message"] ==
             readback <>
               "\n\nServer-computed shape facts:\n" <>
               "- New Initiative \"Import\" leaves index_style unset — tasks render unnumbered." <>
               "\n\nAssumptions:\n- Depth taken from markdown heading levels\n" <>
               "- Struck-through items skipped\n\n" <>
               "Decide: apply — apply this import as read back; correct — don't apply, " <>
               "your corrections say what to change; hold — don't apply, have the agent " <>
               "ask you more questions first."

    refute params["message"] =~ "Settled"

    assert params["requestedSchema"] == schema
    assert %{"type" => "object", "required" => ["decision"], "properties" => props} = schema
    assert props["decision"]["type"] == "string"
    assert props["decision"]["enum"] == ["apply", "correct", "hold"]
    assert props["corrections"]["type"] == "string"
    assert timeout == to_timeout(minute: 5)

    Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    assert [%{"type" => "text", "text" => note}] = rest
    assert note =~ "confirmed"
  end

  test "a mirror batch refuses before any read; the override claim routes to the form" do
    elicitation_capable()

    ops =
      [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Docs"}}] ++
        for i <- 1..12 do
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t#{i}",
            "data" => %{
              "initiative_lid" => "i",
              "title" => "docs\\f#{i}.md",
              "description" => String.duplicate("x", 2_100) <> "#{i}"
            }
          }
        end

    # Bare call: refused, no elicitation, nothing applied.
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {protocol, decoded, _rest} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["gate"] == "batch_shape"
    assert decoded["applied"] == false
    assert decoded["message"] =~ "file-mirror import"
    assert decoded["message"] =~ "`settled` entry quoting their instruction"
    refute_received {:send_elicitation_request, _, _, _}

    # Override claim (readback + settled): the operator vets it on the form,
    # with the server's facts printed under the claim.
    stub_apply_ok()

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{
            operations: ops,
            readback: "One task per source file, as the operator asked.",
            settled: ["Operator: import the docs tree file-per-task"]
          },
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000
    assert params["message"] =~ "Server-computed shape facts:"
    assert params["message"] =~ "12 of 12 new task titles look like file paths/names."
    assert params["message"] =~ "Settled (operator-instructed):"

    Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, _rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
  end

  test "a sub-scale checklist batch holds for the subtasks-or-prose call" do
    elicitation_capable()

    ops = [
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t1",
        "data" => %{
          "initiative_id" => 7,
          "title" => "Set up the environment",
          "description" => "Steps:\n- [ ] install deps\n- [ ] configure env"
        }
      }
    ]

    stub_apply_ok()

    # Without a readback the hold names the content shape, not batch size.
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    assert response.isError == true

    assert [%{"type" => "text", "text" => text}] =
             Enum.map(response.content, &Map.new(&1, fn {k, v} -> {to_string(k), v} end))

    assert text =~ "content shape"
    assert text =~ "Re-call apply_operations"

    # With a readback: the form carries the checklist question; apply keeps prose.
    task =
      Task.async(fn ->
        ApplyOperations.execute(%{operations: ops, readback: "Adding one setup task."}, @frame)
      end)

    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000
    assert params["message"] =~ "2 markdown-checkbox lines"
    assert params["message"] =~ "subtasks"

    Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, _rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
  end

  test "the kill switch disarms the shape pass with the gate" do
    Application.put_env(:doit_mcp, :import_gate_enabled, false)
    stub_apply_ok()

    ops =
      for i <- 1..12 do
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "t#{i}",
          "data" => %{
            "initiative_id" => 7,
            "title" => "docs/f#{i}.md",
            "description" => String.duplicate("x", 2_100) <> "#{i}"
          }
        }
      end

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "corrections come back as the tool result and nothing applies" do
    elicitation_capable()

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000
    assert params["message"] =~ "Assumptions: none stated."

    Elicitation.deliver(%{
      "action" => "accept",
      "content" => %{"decision" => "correct", "corrections" => "Milestones as top-level tasks"}
    })

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["corrections"] == "Milestones as top-level tasks"
  end

  test "decision correct without corrections text holds the batch" do
    elicitation_capable()

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "correct"}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "no corrections"
  end

  test "decision hold withholds the apply and asks for the interview" do
    elicitation_capable()

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "hold"}})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "hold"
    assert decoded["message"] =~ "questions"
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "settled dimensions are echoed as their own block for the operator's veto" do
    elicitation_capable()

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{
            operations: new_initiative_batch(@threshold + 1),
            readback: "Importing 31 tasks.",
            settled: ["Depth: two levels (operator's ask)", "Scope: whole plan (knobs)"]
          },
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000

    assert params["message"] =~
             "Settled (operator-instructed):\n" <>
               "- Depth: two levels (operator's ask)\n- Scope: whole plan (knobs)"

    Elicitation.deliver(%{"action" => "decline"})

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {_, decoded, _} = decode_json_content(response)
    assert decoded["applied"] == false
  end

  test "decline and cancel both hold the batch" do
    elicitation_capable()
    ops = new_initiative_batch(@threshold + 1)

    for {action, expected} <- [{"decline", "declined"}, {"cancel", "did not respond"}] do
      task =
        Task.async(fn ->
          ApplyOperations.execute(%{operations: ops, readback: "Importing 31 tasks."}, @frame)
        end)

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      Elicitation.deliver(%{"action" => action})

      assert {:reply, response, @frame} = Task.await(task, 5_000)
      {_, decoded, _} = decode_json_content(response)
      assert decoded["applied"] == false
      assert decoded["message"] =~ expected
    end
  end

  test "no answer within the window holds the batch" do
    elicitation_capable()
    Application.put_env(:doit_mcp, :import_gate_confirm_timeout, 10)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_confirm_timeout) end)

    task =
      Task.async(fn ->
        ApplyOperations.execute(
          %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
          @frame
        )
      end)

    assert_receive {:send_elicitation_request, _, _, 10}, 2_000

    assert {:reply, response, @frame} = Task.await(task, 5_000)
    {_, decoded, _} = decode_json_content(response)
    assert decoded["applied"] == false
    assert decoded["message"] =~ "did not respond"
  end

  test "an over-threshold existing target gates with no initiative fetch — knobs are parked" do
    elicitation_capable()
    reply_to = self()

    # Only the pressure read may hit the API: the knobs whole-tree read is
    # parked, and a held batch applies nothing.
    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(conn, 0, fn conn ->
        send(reply_to, {:unexpected_request, conn.method, conn.request_path})
        Req.Test.json(conn, %{"data" => %{}})
      end)
    end)

    ops = existing_initiative_batch(@threshold + 1, 7)
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    assert Response.to_protocol(response)["isError"] == true
    refute_received {:unexpected_request, _, _}
    refute_received {:send_elicitation_request, _, _, _}
  end

  # AI-KNOBS-PARKED (m03.04): the knobs exemption at the tool level — settled
  # ai_knobs let an over-threshold batch through; empty knobs gated via the
  # API fetch. Revive with knobless_target/2 and the fetch_initiative wiring
  # in ApplyOperations (the live no-fetch test above then retires).
  #
  # test "an existing target's ai_knobs is fetched over the API; settled knobs pass" do
  #   elicitation_capable()
  #
  #   Req.Test.stub(DoitMcp.Client, fn conn ->
  #     with_pressure(conn, 0, fn conn ->
  #       case {conn.method, conn.request_path} do
  #         {"GET", "/api/v1/initiatives/7"} ->
  #           Req.Test.json(conn, %{"data" => %{"id" => 7, "ai_knobs" => "deploy_day: friday"}})
  #
  #         {"POST", "/api/v1/operations"} ->
  #           Req.Test.json(conn, %{"results" => []})
  #       end
  #     end)
  #   end)
  #
  #   ops = existing_initiative_batch(@threshold + 1, 7)
  #   assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
  #
  #   {_, decoded, _} = decode_json_content(response)
  #   assert decoded["ok"] == true
  #   refute_received {:send_elicitation_request, _, _, _}
  # end
  #
  # test "an existing target with empty ai_knobs gates" do
  #   elicitation_capable()
  #
  #   Req.Test.stub(DoitMcp.Client, fn conn ->
  #     with_pressure(conn, 0, fn conn ->
  #       assert {conn.method, conn.request_path} == {"GET", "/api/v1/initiatives/7"}
  #       Req.Test.json(conn, %{"data" => %{"id" => 7, "ai_knobs" => nil}})
  #     end)
  #   end)
  #
  #   ops = existing_initiative_batch(@threshold + 1, 7)
  #   assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
  #
  #   assert Response.to_protocol(response)["isError"] == true
  #   refute_received {:send_elicitation_request, _, _, _}
  # end

  describe "cumulative trigger across chunks (m03.03 item 5.11.2)" do
    test "two sub-threshold chunks crossing the line fire the gate" do
      start_counter()
      elicitation_capable()
      stub_get_and_apply(nil)

      # Chunk 1: 20 adds — coherent, under every bound; applies silently.
      execute_ok(existing_initiative_batch(20, 7))
      refute_received {:send_elicitation_request, _, _, _}

      # The DB window now reports the ramp nearly ridden out — one more
      # coherent chunk crosses the RAMP bound and is held for a readback.
      stub_get_and_apply(nil, 120)
      ops = existing_initiative_batch(15, 7)
      assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "15 tasks"
      assert text =~ "135 this session"
      refute_received {:send_elicitation_request, _, _, _}
    end

    test "post-confirm silence: later chunks into a confirmed Initiative never re-ask" do
      start_counter()
      elicitation_capable()
      stub_get_and_apply(nil)

      task =
        Task.async(fn ->
          ApplyOperations.execute(
            %{
              operations: existing_initiative_batch(@threshold + 1, 7),
              readback: "Importing 31 tasks."
            },
            @frame
          )
        end)

      # The count-only task_count stub carries no initiative_index_style →
      # the confirm's target-style read fails open and prints no line.
      assert_receive {:send_elicitation_request, params, _, _}, 2_000
      refute params["message"] =~ "Target Initiative index_style"
      Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})
      assert {:reply, _response, @frame} = Task.await(task, 5_000)

      # ai_knobs is STILL empty and the window far over the line — but the
      # operator already confirmed this Initiative this session.
      stub_get_and_apply(nil, 200)
      execute_ok(existing_initiative_batch(15, 7))
      refute_received {:send_elicitation_request, _, _, _}
    end

    # AI-KNOBS-PARKED (m03.04): settled knobs silenced the gate for a whole
    # session. Revive with the knobs exemption.
    #
    # test "post-knobs silence: once ai_knobs is settled, an over-the-line session stays quiet" do
    #   start_counter()
    #   elicitation_capable()
    #   stub_get_and_apply("deploy_day: friday")
    #
    #   execute_ok(existing_initiative_batch(25, 7))
    #
    #   # The window reports far over every bound — but the fetch finds
    #   # settled knobs.
    #   stub_get_and_apply("deploy_day: friday", 200)
    #   execute_ok(existing_initiative_batch(10, 7))
    #   refute_received {:send_elicitation_request, _, _, _}
    # end

    test "chunks on a fresh Initiative keep counting across the lid → real-id switch" do
      start_counter()
      elicitation_capable()
      stub_create_echo_and_get(57, nil)

      # Chunk 1 CREATES the Initiative at the fresh floor (8 adds — flows
      # silently); its count lands under the real id the response echoed.
      execute_ok(new_initiative_batch(ImportGate.fresh_threshold()))
      refute_received {:send_elicitation_request, _, _, _}

      # Chunk 2 can only reference it by real id: the DATABASE carries the
      # count across the lid → real-id switch, and past the ramp bound the
      # crossing batch is held for a readback.
      stub_create_echo_and_get(57, nil, 120)
      ops = existing_initiative_batch(15, 57)
      assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "15 tasks"
      assert text =~ "135 this session"
    end

    test "recorded counts match gate counts across resolution modes: a parent-anchored chunk and an initiative_id chunk share one total" do
      start_counter()
      elicitation_capable()
      stub_parent_resolve_and_apply(42, 7)

      # Chunk 1: 20 parent-anchored adds — applies, and is recorded under the
      # parent's Initiative (the same key the gate reads).
      execute_ok(parent_anchored_batch(20, 42))
      refute_received {:send_elicitation_request, _, _, _}

      # Chunk 2 references the SAME Initiative by id past the ramp bound —
      # one DB total serves both resolution modes.
      stub_parent_resolve_and_apply(42, 7, 120)
      ops = existing_initiative_batch(15, 7)
      assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "15 tasks"
      assert text =~ "135 this session"
    end

    test "a confirm granted under the lid carries to the created id — later chunks never re-ask" do
      start_counter()
      elicitation_capable()
      stub_create_echo_and_get(57, nil)

      task =
        Task.async(fn ->
          ApplyOperations.execute(
            %{operations: new_initiative_batch(@threshold + 1), readback: "Importing 31 tasks."},
            @frame
          )
        end)

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})
      assert {:reply, _response, @frame} = Task.await(task, 5_000)

      # Knobs still empty and the window far over the line — but the
      # operator's confirm followed the Initiative to its real id.
      stub_create_echo_and_get(57, nil, 200)
      execute_ok(existing_initiative_batch(15, 57))
      refute_received {:send_elicitation_request, _, _, _}
    end
  end

  describe "the fresh floor (m03.04 3.1 iteration 3)" do
    test "a just-created Initiative's scaffold past the floor is held without a readback" do
      # The observed failure, replayed: the Initiative was created moments
      # ago (task_count says so), and the scaffold batch — 12 adds, coherent,
      # under every old bound — arrives by real id. It must meet the confirm.
      elicitation_capable()
      stub_fresh_create_echo_and_get(57, 2)

      ops = existing_initiative_batch(12, 57)
      assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "just created"
      assert text =~ "#{ImportGate.fresh_threshold()} cumulative task-adds"
      assert text =~ "this batch adds 12 (14 this session)"
      assert text =~ "SOURCE"
      refute_received {:send_elicitation_request, _, _, _}
    end

    test "with a readback the operator confirms the fresh import; the confirm settles it" do
      start_counter()
      elicitation_capable()
      stub_fresh_create_echo_and_get(57)

      # An in-batch Initiative is fresh by definition — the floor gates its
      # 12-add scaffold with no freshness read.
      task =
        Task.async(fn ->
          ApplyOperations.execute(
            %{
              operations: new_initiative_batch(12),
              readback: "Importing the first two milestones from PLAN.md, one level deep."
            },
            @frame
          )
        end)

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})

      assert {:reply, response, @frame} = Task.await(task, 5_000)
      {protocol, decoded, rest} = decode_json_content(response)
      assert protocol["isError"] == false
      assert decoded["ok"] == true
      assert [%{"type" => "text", "text" => note}] = rest
      assert note =~ "confirmed"

      # The confirm followed the lid to the real id: the next chunk lands in
      # a STILL-fresh Initiative (the stub vouches), yet nothing re-asks —
      # one confirm settles the session.
      stub_fresh_create_echo_and_get(57, 12)
      execute_ok(existing_initiative_batch(9, 57))
      refute_received {:send_elicitation_request, _, _, _}
    end

    test "a fresh Initiative's first #{ImportGate.fresh_threshold()} adds flow — casual creations stay silent" do
      elicitation_capable()
      stub_fresh_create_echo_and_get(57)

      execute_ok(new_initiative_batch(ImportGate.fresh_threshold()))
      refute_received {:send_elicitation_request, _, _, _}
    end
  end

  describe "parent-anchored adds (m03.04 item 2.18)" do
    test "an over-threshold parent-anchored batch is held — no more dodging via parent_id" do
      elicitation_capable()
      stub_parent_resolve_and_apply(42, 7)

      ops = parent_anchored_batch(@threshold + 1, 42)
      assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

      protocol = Response.to_protocol(response)
      assert protocol["isError"] == true
      assert [%{"type" => "text", "text" => text}] = protocol["content"]
      assert text =~ "readback"
      assert text =~ "#{@threshold + 1} tasks"
    end

    test "with a readback the operator is elicited, and a confirm applies the batch" do
      elicitation_capable()
      # task_count serves the target's index_style → the confirm form carries
      # the target-style line even with no shape facts (unremarkable adds).
      stub_parent_resolve_and_apply(42, 7, 0, %{"initiative_index_style" => "none"})

      task =
        Task.async(fn ->
          ApplyOperations.execute(
            %{
              operations: parent_anchored_batch(@threshold + 1, 42),
              readback: "Importing 31 tasks under an existing task."
            },
            @frame
          )
        end)

      assert_receive {:send_elicitation_request, params, _, _}, 2_000

      assert params["message"] =~
               "- Target Initiative index_style: none — tasks render unnumbered."

      Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})

      assert {:reply, response, @frame} = Task.await(task, 5_000)
      {protocol, decoded, _} = decode_json_content(response)
      assert protocol["isError"] == false
      assert decoded["ok"] == true
    end

    test "a below-threshold parent-anchored batch applies straight through, one read per unique parent" do
      elicitation_capable()
      stub_parent_resolve_and_apply(42, 7)

      execute_ok(parent_anchored_batch(@threshold, 42))
      refute_received {:send_elicitation_request, _, _, _}

      # All 30 adds anchor on the same parent — resolved exactly once.
      assert_received {:task_read, "/api/v1/tasks/42"}
      refute_received {:task_read, _}
    end

    test "an unresolvable parent (404 read) stays dropped — the gate passes, the apply speaks" do
      elicitation_capable()

      Req.Test.stub(DoitMcp.Client, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/v1/tasks/" <> _} ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"error" => %{"status" => 404, "code" => "not_found"}})

          {"POST", "/api/v1/operations"} ->
            Req.Test.json(conn, %{"results" => []})
        end
      end)

      execute_ok(parent_anchored_batch(@threshold + 1, 999))
      refute_received {:send_elicitation_request, _, _, _}
    end
  end
end
