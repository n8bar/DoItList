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
  @confirm_url "http://localhost:4000/initiatives/7#import-confirm"

  # The gate ships armed (DOITLIST_IMPORT_GATE=off opts out); pin it on here
  # so these behavior tests stay deterministic against the container's
  # ambient environment.
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  # Any test that resolves a confirm (form answer or in-app consult) starts
  # the gate's session memory — Counter plus PendingConfirm; everything else
  # runs memory-less (both degrade to zero/no-op), i.e. single-batch
  # semantics.
  defp start_gate_state do
    counter = :"#{__MODULE__}.Counter"
    pending = :"#{__MODULE__}.PendingConfirm"
    start_supervised!({DoitMcp.ImportGate.Counter, name: counter})
    start_supervised!({DoitMcp.ImportGate.PendingConfirm, name: pending})

    previous_counter = Application.fetch_env(:doit_mcp, :import_gate_counter)
    previous_pending = Application.fetch_env(:doit_mcp, :import_gate_pending_confirm)
    Application.put_env(:doit_mcp, :import_gate_counter, counter)
    Application.put_env(:doit_mcp, :import_gate_pending_confirm, pending)

    on_exit(fn ->
      case previous_counter do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_counter, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_counter)
      end

      case previous_pending do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_pending_confirm, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_pending_confirm)
      end
    end)
  end

  defp fake_session(capabilities) do
    name = :"#{__MODULE__}.FakeSession"
    start_supervised!({FakeSession, name: name, capabilities: capabilities, forward_to: self()})

    previous = Application.fetch_env(:doit_mcp, :elicitation_session_name)
    Application.put_env(:doit_mcp, :elicitation_session_name, name)

    # The fake session IS this test's channel to the "client" — it forwards
    # every elicitation straight here, so declare it reachable in place of
    # the real transport's stream check.
    Application.put_env(:doit_mcp, :elicitation_reachable, true)

    on_exit(fn ->
      Application.delete_env(:doit_mcp, :elicitation_reachable)

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

  # Serves the import-confirm API (m03.04 item 30) ahead of a stub's other
  # clauses. GET by hash answers the adapter's consult: `:none` → 404
  # (nothing recorded), a map → the row merged over pending defaults. POST
  # parks — echoing a pending row + the card URL — and reports the decoded
  # body as {:parked, body} to `reply_to`.
  defp with_confirm_api(conn, reply_to, consult, fallback) do
    case {conn.method, conn.request_path} do
      {"GET", "/api/v1/import_confirms/" <> hash} ->
        case consult do
          :none ->
            conn
            |> Plug.Conn.put_status(404)
            |> Req.Test.json(%{"error" => %{"status" => 404, "code" => "not_found"}})

          row when is_map(row) ->
            defaults = %{
              "payload_hash" => hash,
              "status" => "pending",
              "corrections" => nil,
              "url" => @confirm_url
            }

            Req.Test.json(conn, %{"data" => Map.merge(defaults, row)})
        end

      {"POST", "/api/v1/import_confirms"} ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        parked = Jason.decode!(body)
        send(reply_to, {:parked, parked})

        Req.Test.json(conn, %{
          "data" => %{
            "payload_hash" => parked["payload_hash"],
            "status" => "pending",
            "corrections" => nil,
            "url" => @confirm_url
          }
        })

      _ ->
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
        &with_confirm_api(&1, reply_to, :none, fn conn ->
          case {conn.method, conn.request_path} do
            {"GET", "/api/v1/tasks/" <> _} ->
              send(reply_to, {:task_read, conn.request_path})

              Req.Test.json(conn, %{
                "data" => %{"id" => parent_id, "initiative_id" => initiative_id}
              })

            # The post-apply repo-marker read (item 26.2): no summaries, no
            # suggestion.
            {"GET", "/api/v1/initiatives"} ->
              Req.Test.json(conn, %{"data" => []})

            # AI-KNOBS-PARKED (m03.04): unreached — the gate's knobs fetch is
            # parked; a revived fetch hits it again.
            {"GET", "/api/v1/initiatives/" <> _} ->
              Req.Test.json(conn, %{"data" => %{"id" => initiative_id, "ai_knobs" => nil}})

            {"POST", "/api/v1/operations"} ->
              Req.Test.json(conn, %{"results" => []})
          end
        end),
        extra
      )
    end)
  end

  defp stub_apply_ok(pressure \\ 0, consult \\ :none) do
    reply_to = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(
        conn,
        pressure,
        &with_confirm_api(&1, reply_to, consult, fn conn ->
          case {conn.method, conn.request_path} do
            # The post-apply repo-marker read (item 26.2): no summaries served,
            # so no suggestion rides these gate assertions.
            {"GET", "/api/v1/initiatives"} ->
              Req.Test.json(conn, %{"data" => []})

            {"POST", "/api/v1/operations"} ->
              Req.Test.json(conn, %{"results" => []})
          end
        end)
      )
    end)
  end

  defp decode_json_content(response) do
    protocol = Response.to_protocol(response)
    assert [%{"type" => "text", "text" => text} | rest] = protocol["content"]
    {protocol, Jason.decode!(text), rest}
  end

  defp stub_get_and_apply(knobs, pressure \\ 0, consult \\ :none) do
    reply_to = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(
        conn,
        pressure,
        &with_confirm_api(&1, reply_to, consult, fn conn ->
          case {conn.method, conn.request_path} do
            # AI-KNOBS-PARKED (m03.04): unreached — the gate's knobs fetch is
            # parked; a revived fetch hits it (and the knobs arg matters) again.
            {"GET", "/api/v1/initiatives/7"} ->
              Req.Test.json(conn, %{"data" => %{"id" => 7, "ai_knobs" => knobs}})

            # The post-apply repo-marker read (item 26.2): no summaries, no
            # suggestion.
            {"GET", "/api/v1/initiatives"} ->
              Req.Test.json(conn, %{"data" => []})

            {"POST", "/api/v1/operations"} ->
              Req.Test.json(conn, %{"results" => []})
          end
        end)
      )
    end)
  end

  # POST echoes the created Initiative's lid → real id (the wire shape for
  # creates); GET serves its ai_knobs (AI-KNOBS-PARKED: unreached while the
  # gate's knobs fetch is parked; a revived fetch hits it again).
  defp stub_create_echo_and_get(initiative_id, knobs, pressure \\ 0) do
    reply_to = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(
        conn,
        pressure,
        &with_confirm_api(&1, reply_to, :none, fn conn ->
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

            # The post-apply repo-marker read (item 26.2): no summaries, no
            # suggestion.
            {"GET", "/api/v1/initiatives"} ->
              Req.Test.json(conn, %{"data" => []})

            {"GET", "/api/v1/initiatives/" <> _} ->
              Req.Test.json(conn, %{"data" => %{"id" => initiative_id, "ai_knobs" => knobs}})
          end
        end)
      )
    end)
  end

  # Like stub_create_echo_and_get, but task_count also carries a FRESH
  # initiative_created_at (m03.04 3.1 iteration 3) — the Initiative is still
  # inside its freshness window, so fresh?/1 reads true over HTTP.
  defp stub_fresh_create_echo_and_get(initiative_id, pressure \\ 0) do
    created = DateTime.utc_now() |> DateTime.add(-2, :minute) |> DateTime.to_iso8601()
    reply_to = self()

    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_confirm_api(conn, reply_to, :none, fn conn ->
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
    end)
  end

  defp execute_ok(params) when is_map(params) do
    assert {:reply, response, @frame} = ApplyOperations.execute(params, @frame)
    {protocol, decoded, _rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
  end

  defp execute_ok(ops), do: execute_ok(%{operations: ops})

  # A gated call now returns PROMPTLY (m03.04 item 27.1): the composed
  # readback rides a NORMAL result tagged confirmation_pending while the
  # form waits out-of-band — executing inline (no Task) is itself the
  # no-block assertion, since the old contract parked here for the answer.
  defp execute_pending(params) do
    assert {:reply, response, @frame} = ApplyOperations.execute(params, @frame)
    {protocol, decoded, _rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["status"] == "confirmation_pending"
    assert decoded["applied"] == false
    decoded
  end

  # The out-of-band form's answer, delivered to the detached waiter;
  # awaiting the waiter's exit guarantees the answer's session-memory
  # effects landed before the test re-calls.
  defp answer_form(result) do
    waiter = form_waiter()
    ref = Process.monitor(waiter)
    Elicitation.deliver(result)
    assert_receive {:DOWN, ^ref, :process, ^waiter, _reason}, 2_000
  end

  defp form_waiter do
    session = Process.whereis(:"#{__MODULE__}.FakeSession")
    [{waiter, :async}] = Registry.lookup(DoitMcp.Elicitation.Registry, session)
    waiter
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

  test "a client without the elicitation capability still gates — the app carries the confirm" do
    start_gate_state()
    fake_session(%{"sampling" => %{}})
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    refute Elicitation.client_supports_elicitation?()

    # The same readback demand every client meets.
    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    assert Response.to_protocol(response)["isError"] == true

    # With one, the confirm parks URL-only: no form to ride, nothing skipped.
    decoded = execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert decoded["confirm_url"] == @confirm_url
    assert_received {:parked, _body}
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "gated batch without readback is rejected unapplied, telling the agent what to supply" do
    elicitation_capable()
    stub_apply_ok()

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

  test "a gated call returns the readback promptly; a form approval lets the re-call flow" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    readback = "Importing PLAN.md as 31 tasks under one new Initiative, two levels deep."
    assumptions = ["Depth taken from markdown heading levels", "Struck-through items skipped"]

    decoded = execute_pending(%{operations: ops, readback: readback, assumptions: assumptions})

    # The result carries the composed message VERBATIM — readback, the
    # server's facts (the in-batch Initiative's index_style — always
    # notable), assumptions, then the decision line naming all three choices
    # — plus the re-call contract. No `settled` passed → no Settled block;
    # an in-batch target → no target-style read.
    expected_message =
      readback <>
        "\n\nServer-computed shape facts:\n" <>
        "- New Initiative \"Import\" leaves index_style unset — tasks render unnumbered." <>
        "\n\nAssumptions:\n- Depth taken from markdown heading levels\n" <>
        "- Struck-through items skipped\n\n" <>
        "Decide: apply — apply this import as read back; correct — don't apply, " <>
        "your corrections say what to change; hold — don't apply, have the agent " <>
        "ask you more questions first."

    assert decoded["readback"] == expected_message
    refute decoded["readback"] =~ "Settled"
    assert decoded["confirm_url"] == @confirm_url
    assert decoded["message"] =~ "confirm_url"
    assert decoded["message"] =~ "re-call"

    # The form went out out-of-band with the SAME message, on the generous
    # expiry — the call never waited on it.
    assert_receive {:send_elicitation_request, params, schema, timeout}, 2_000
    assert params["message"] == expected_message
    assert params["requestedSchema"] == schema
    assert %{"type" => "object", "required" => ["decision"], "properties" => props} = schema
    assert props["decision"]["type"] == "string"
    assert props["decision"]["enum"] == ["apply", "correct", "hold"]
    assert props["corrections"]["type"] == "string"
    assert timeout == to_timeout(minute: 10)

    # The operator answers the form; the session remembers the approval, so
    # the plain re-call flows — no second form.
    answer_form(%{"action" => "accept", "content" => %{"decision" => "apply"}})
    execute_ok(ops)
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "an expired form is a no-op; the in-app decision still resolves the confirm" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()
    Application.put_env(:doit_mcp, :import_gate_confirm_expiry, 10)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_confirm_expiry) end)

    ops = new_initiative_batch(@threshold + 1)
    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, _, _, 10}, 2_000

    # The waiter expires unanswered (the tiny window plus the skew second).
    waiter = form_waiter()
    ref = Process.monitor(waiter)
    assert_receive {:DOWN, ^ref, :process, ^waiter, _reason}, 3_000

    # A late form answer lands nowhere. The operator's in-app approval —
    # the channel with no clock — then resolves the still-pending confirm on
    # a plain re-call; the confirm NOTE proves the consult ran (a leaked
    # late approval would have applied noteless via the gate).
    Elicitation.deliver(%{"action" => "accept", "content" => %{"decision" => "apply"}})

    stub_apply_ok(0, %{"status" => "approved"})

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    {protocol, decoded, rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    assert [%{"type" => "text", "text" => note}] = rest
    assert note =~ "confirmed"
  end

  test "a mirror batch refuses before any read; the override claim routes to the readback" do
    start_gate_state()
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

    # Override claim (readback + settled): the operator vets it — the
    # server's facts print under the claim in both the prompt return and the
    # out-of-band form.
    stub_apply_ok()

    override = %{
      operations: ops,
      readback: "One task per source file, as the operator asked.",
      settled: ["Operator: import the docs tree file-per-task"]
    }

    decoded = execute_pending(override)
    assert decoded["readback"] =~ "Server-computed shape facts:"
    assert decoded["readback"] =~ "12 of 12 new task titles look like file paths/names."
    assert decoded["readback"] =~ "Settled (operator-instructed):"

    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000
    assert params["message"] == decoded["readback"]

    # The form approval covers the batch: the re-call (same claim) applies.
    answer_form(%{"action" => "accept", "content" => %{"decision" => "apply"}})
    execute_ok(override)
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "a sub-scale checklist batch holds for the subtasks-or-prose call" do
    start_gate_state()
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

    # With a readback: the prompt return (and the form, same message) carries
    # the checklist ask — the checkbox fact printing ONCE (item 27.3).
    decoded = execute_pending(%{operations: ops, readback: "Adding one setup task."})
    assert decoded["readback"] =~ "2 markdown-checkbox lines sit inside 1 new descriptions."
    assert decoded["readback"] =~ "subtasks"
    assert length(String.split(decoded["readback"], "markdown-checkbox lines")) == 2

    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000
    assert params["message"] == decoded["readback"]

    # apply keeps prose: the form approval lets the plain re-call flow.
    answer_form(%{"action" => "accept", "content" => %{"decision" => "apply"}})
    execute_ok(ops)
    refute_received {:send_elicitation_request, _, _, _}
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

  test "form corrections come back on the re-call and nothing applies" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, params, _schema, _timeout}, 2_000
    assert params["message"] =~ "Assumptions: none stated."

    answer_form(%{
      "action" => "accept",
      "content" => %{"decision" => "correct", "corrections" => "Milestones as top-level tasks"}
    })

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["corrections"] == "Milestones as top-level tasks"
  end

  test "a form correct without corrections text holds the batch on the re-call" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    answer_form(%{"action" => "accept", "content" => %{"decision" => "correct"}})

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "no corrections"
  end

  test "a form hold withholds the apply and asks for the interview on the re-call" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()

    ops = new_initiative_batch(@threshold + 1)
    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    answer_form(%{"action" => "accept", "content" => %{"decision" => "hold"}})

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "hold"
    assert decoded["message"] =~ "questions"
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "settled dimensions are echoed as their own block for the operator's veto" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()

    decoded =
      execute_pending(%{
        operations: new_initiative_batch(@threshold + 1),
        readback: "Importing 31 tasks.",
        settled: ["Depth: two levels (operator's ask)", "Scope: whole plan (knobs)"]
      })

    assert decoded["readback"] =~
             "Settled (operator-instructed):\n" <>
               "- Depth: two levels (operator's ask)\n- Scope: whole plan (knobs)"
  end

  test "a form decline latches for the re-call; the next confirm starts fresh" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()
    ops = new_initiative_batch(@threshold + 1)

    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    answer_form(%{"action" => "decline"})

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)
    {_, decoded, _} = decode_json_content(response)
    assert decoded["applied"] == false
    assert decoded["message"] =~ "declined"

    # Consumed: the same batch gated again starts a fresh confirm, new form.
    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, _, _, _}, 2_000
  end

  test "a cancelled form decides nothing — the pending confirm stands for chat or a fresh form" do
    start_gate_state()
    elicitation_capable()
    stub_apply_ok()
    ops = new_initiative_batch(@threshold + 1)

    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, _, _, _}, 2_000
    answer_form(%{"action" => "cancel"})

    # No decision latched: the re-call re-prompts with a fresh form, and the
    # in-app decision still resolves the pending confirm.
    execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
    assert_receive {:send_elicitation_request, _, _, _}, 2_000

    stub_apply_ok(0, %{"status" => "approved"})

    assert {:reply, response, @frame} = ApplyOperations.execute(%{operations: ops}, @frame)

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
  end

  test "an over-threshold existing target gates with no initiative fetch — knobs are parked" do
    elicitation_capable()
    reply_to = self()

    # Only the pressure read and the confirm consult may hit the API: the
    # knobs whole-tree read is parked, and a held batch applies nothing.
    Req.Test.stub(DoitMcp.Client, fn conn ->
      with_pressure(conn, 0, fn conn ->
        with_confirm_api(conn, reply_to, :none, fn conn ->
          send(reply_to, {:unexpected_request, conn.method, conn.request_path})
          Req.Test.json(conn, %{"data" => %{}})
        end)
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
      start_gate_state()
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
      start_gate_state()
      elicitation_capable()
      stub_get_and_apply(nil)

      ops = existing_initiative_batch(@threshold + 1, 7)
      decoded = execute_pending(%{operations: ops, readback: "Importing 31 tasks."})

      # The count-only task_count stub carries no initiative_index_style →
      # the confirm's target-style read fails open and prints no line.
      refute decoded["readback"] =~ "Target Initiative index_style"

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      answer_form(%{"action" => "accept", "content" => %{"decision" => "apply"}})
      execute_ok(ops)

      # The window far over the line — but the operator already confirmed
      # this Initiative this session.
      stub_get_and_apply(nil, 200)
      execute_ok(existing_initiative_batch(15, 7))
      refute_received {:send_elicitation_request, _, _, _}
    end

    # AI-KNOBS-PARKED (m03.04): settled knobs silenced the gate for a whole
    # session. Revive with the knobs exemption.
    #
    # test "post-knobs silence: once ai_knobs is settled, an over-the-line session stays quiet" do
    #   start_gate_state()
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
      start_gate_state()
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
      start_gate_state()
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
      start_gate_state()
      elicitation_capable()
      stub_create_echo_and_get(57, nil)

      ops = new_initiative_batch(@threshold + 1)
      execute_pending(%{operations: ops, readback: "Importing 31 tasks."})
      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      answer_form(%{"action" => "accept", "content" => %{"decision" => "apply"}})
      execute_ok(ops)

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
      start_gate_state()
      elicitation_capable()
      stub_fresh_create_echo_and_get(57)

      # An in-batch Initiative is fresh by definition — the floor gates its
      # 12-add scaffold with no freshness read.
      ops = new_initiative_batch(12)

      execute_pending(%{
        operations: ops,
        readback: "Importing the first two milestones from PLAN.md, one level deep."
      })

      assert_receive {:send_elicitation_request, _, _, _}, 2_000
      answer_form(%{"action" => "accept", "content" => %{"decision" => "apply"}})
      execute_ok(ops)

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

    test "with a readback the confirm carries the target style, and a form approval applies" do
      start_gate_state()
      elicitation_capable()
      # task_count serves the target's index_style → the readback carries
      # the target-style line even with no shape facts (unremarkable adds).
      stub_parent_resolve_and_apply(42, 7, 0, %{"initiative_index_style" => "none"})

      ops = parent_anchored_batch(@threshold + 1, 42)

      decoded =
        execute_pending(%{
          operations: ops,
          readback: "Importing 31 tasks under an existing task."
        })

      assert decoded["readback"] =~
               "- Target Initiative index_style: none — tasks render unnumbered."

      assert_receive {:send_elicitation_request, params, _, _}, 2_000
      assert params["message"] == decoded["readback"]

      answer_form(%{"action" => "accept", "content" => %{"decision" => "apply"}})
      execute_ok(ops)
      refute_received {:send_elicitation_request, _, _, _}
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
