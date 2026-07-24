defmodule DoitMcp.StdioImportGateE2eTest.FakeIO do
  @moduledoc """
  Minimal Erlang I/O server standing in for the OS pipe — a copy of
  `DoitMcp.StdioTransportTest.FakeIO` (test files compile standalone; there
  is no shared support path). The test feeds stdin lines (or EOF) and
  receives everything written to stdout as `{:stdout, binary}` messages.

  Implements just what the transport uses — `{:get_line, ...}` for the
  reader, parking the request while no line is queued (a real pipe blocks) —
  and `{:put_chars, ...}` for writes.
  """

  # Deliberately unlinked: the test process exits non-:normal even on
  # success, and a link would kill the device before the transport's reader
  # is torn down — the reader's parked read then errors :terminated instead
  # of seeing a clean :eof. The owner monitor below handles lifecycle.
  def open(owner) do
    spawn(fn ->
      Process.monitor(owner)
      loop(%{owner: owner, lines: :queue.new(), eof: false, waiter: nil})
    end)
  end

  def feed(device, line) when is_binary(line), do: send(device, {:feed, line})

  def feed_eof(device), do: send(device, :feed_eof)

  defp loop(state) do
    receive do
      {:io_request, from, reply_as, request} ->
        loop(io_request(request, from, reply_as, state))

      {:feed, line} ->
        loop(pump(%{state | lines: :queue.in(line, state.lines)}))

      :feed_eof ->
        loop(pump(%{state | eof: true}))

      # The owning test is gone. Don't just exit: teardown races us — if the
      # device dies before the transport's reader, the reader sees
      # {:error, :terminated} and the transport logs a spurious error. Serve
      # :eof until everyone's gone.
      {:DOWN, _ref, :process, _pid, _reason} ->
        drain(pump(%{state | eof: true}))
    end
  end

  defp drain(state) do
    receive do
      {:io_request, from, reply_as, {:get_line, _encoding, _prompt}} ->
        reply(from, reply_as, :eof)
        drain(state)

      {:io_request, from, reply_as, _request} ->
        reply(from, reply_as, :ok)
        drain(state)
    after
      5_000 -> :ok
    end
  end

  defp io_request({:put_chars, _encoding, chars}, from, reply_as, state) do
    send(state.owner, {:stdout, IO.chardata_to_string(chars)})
    reply(from, reply_as, :ok)
    state
  end

  defp io_request({:put_chars, _encoding, mod, fun, args}, from, reply_as, state) do
    send(state.owner, {:stdout, IO.chardata_to_string(apply(mod, fun, args))})
    reply(from, reply_as, :ok)
    state
  end

  defp io_request({:get_line, _encoding, _prompt}, from, reply_as, state) do
    pump(%{state | waiter: {from, reply_as}})
  end

  defp io_request(_other, from, reply_as, state) do
    reply(from, reply_as, {:error, :enotsup})
    state
  end

  # Serve the parked reader as soon as a line (or EOF) is available.
  defp pump(%{waiter: nil} = state), do: state

  defp pump(%{waiter: {from, reply_as}} = state) do
    case :queue.out(state.lines) do
      {{:value, line}, rest} ->
        reply(from, reply_as, line)
        %{state | lines: rest, waiter: nil}

      {:empty, _} when state.eof ->
        reply(from, reply_as, :eof)
        %{state | waiter: nil}

      {:empty, _} ->
        state
    end
  end

  defp reply(from, reply_as, reply), do: send(from, {:io_reply, reply_as, reply})
end

defmodule DoitMcp.StdioImportGateE2eTest do
  # async: false — boots the production stdio tree under its real global
  # registry names and swaps global app env.
  use ExUnit.Case, async: false

  alias DoitMcp.ImportGate
  alias DoitMcp.StdioImportGateE2eTest.FakeIO

  # Session/transport lifecycles log; keep test output clean.
  @moduletag :capture_log

  @threshold ImportGate.threshold()

  # Item 2.11.2's live proof: the armed-by-default import gate end-to-end
  # over wire-level JSON-RPC frames against the REAL production tree —
  # session, concurrent transport, Counter under its production name — with
  # only the OS pipe faked and the HTTP API stubbed. One test shows the
  # confirm form and applies on confirm; the other shows the cumulative
  # trigger firing on the chunk that crosses the threshold, across the
  # created Initiative's lid → real-id switch.

  setup do
    # Determinism against any ambient DOITLIST_IMPORT_GATE in the container.
    Application.put_env(:doit_mcp, :import_gate_enabled, true)

    # The tool task runs under the session's Task.Supervisor — outside the
    # test's $callers chain — so Req.Test's per-process stub ownership can't
    # reach it. Inject a plain plug fun instead (DoitMcp.Client merges the
    # :req_options app env).
    previous_req = Application.fetch_env(:doit_mcp, :req_options)

    on_exit(fn ->
      Application.delete_env(:doit_mcp, :import_gate_enabled)

      case previous_req do
        {:ok, value} -> Application.put_env(:doit_mcp, :req_options, value)
        :error -> Application.delete_env(:doit_mcp, :req_options)
      end
    end)

    # The gate's session memory, under its production name — the application
    # tree doesn't start in tests (children(:test) == []), and the cumulative
    # case needs chunk 1's applied count remembered.
    start_supervised!(DoitMcp.ImportGate.Counter)

    device = FakeIO.open(self())

    start_supervised!(
      {DoitMcp.Stdio.Supervisor, io_device: device, session_idle_timeout: to_timeout(minute: 10)}
    )

    {:ok, device: device}
  end

  defp stub_http(fun), do: Application.put_env(:doit_mcp, :req_options, plug: fun)

  # POST echoes the created Initiative's lid → real id (the wire shape for
  # creates) and reports each apply to the test; GET serves its ai_knobs
  # (still empty — fresh) and the DB-window pressure read (chunk 1's 20
  # tasks all landed inside the window).
  defp stub_api(test_pid) do
    stub_http(fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/api/v1/operations"} ->
          send(test_pid, :applied)

          Req.Test.json(conn, %{
            "results" => [
              %{
                "index" => 0,
                "lid" => "i",
                "status" => "ok",
                "data" => %{"id" => 57, "type" => "initiative"}
              }
            ]
          })

        {"GET", "/api/v1/initiatives/57/task_count"} ->
          Req.Test.json(conn, %{"data" => %{"count" => 20}})

        {"GET", "/api/v1/initiatives/57"} ->
          Req.Test.json(conn, %{"data" => %{"id" => 57, "ai_knobs" => nil}})
      end
    end)
  end

  defp send_frame(device, map), do: FakeIO.feed(device, Jason.encode!(map) <> "\n")

  defp recv_frame do
    assert_receive {:stdout, line}, 5_000
    Jason.decode!(line)
  end

  # The pipeline is a single ordered lane (FakeIO -> reader -> transport ->
  # session mailbox), so the handshake needs no explicit synchronization
  # before the next frame.
  defp handshake(device) do
    send_frame(device, %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "import-gate-e2e", "version" => "1.0"},
        "capabilities" => %{"elicitation" => %{}}
      }
    })

    assert %{"id" => 1, "result" => %{"serverInfo" => _}} = recv_frame()

    send_frame(device, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    :ok
  end

  defp fresh_import_ops(task_count) do
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

  defp chunk_ops(task_count, initiative_id) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"initiative_id" => initiative_id, "title" => "task #{i}"}
      }
    end
  end

  defp tools_call(id, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "apply_operations", "arguments" => arguments}
    }
  end

  defp decoded_tool_text(result) do
    assert [%{"type" => "text", "text" => text} | rest] = result["content"]
    {Jason.decode!(text), rest}
  end

  test "a gated import shows the confirm form over real stdio and applies on confirm",
       %{device: device} do
    stub_api(self())
    handshake(device)

    send_frame(
      device,
      tools_call(2, %{
        "operations" => fresh_import_ops(@threshold + 1),
        "readback" => "Importing PLAN.md as #{@threshold + 1} tasks under one new Initiative.",
        "assumptions" => ["Depth taken from markdown heading levels"]
      })
    )

    # The confirm form goes OUT while the tools/call is still unanswered.
    assert %{
             "method" => "elicitation/create",
             "id" => elicitation_id,
             "params" => %{"message" => message, "requestedSchema" => schema}
           } = recv_frame()

    # The form: readback + assumptions, then the three-option decision line.
    assert message =~ "Importing PLAN.md"
    assert message =~ "Depth taken from markdown heading levels"
    assert message =~ "apply — apply this import as read back"
    assert message =~ "correct — don't apply"
    assert message =~ "hold — don't apply"
    assert schema["properties"]["decision"]["enum"] == ["apply", "correct", "hold"]

    # Nothing applied while the operator is reading.
    refute_received :applied

    send_frame(device, %{
      "jsonrpc" => "2.0",
      "id" => elicitation_id,
      "result" => %{"action" => "accept", "content" => %{"decision" => "apply"}}
    })

    assert %{"id" => 2, "result" => result} = recv_frame()
    assert result["isError"] == false

    {decoded, rest} = decoded_tool_text(result)
    assert decoded["ok"] == true
    assert_received :applied
    assert [%{"type" => "text", "text" => note}] = rest
    assert note =~ "confirmed"
  end

  test "two sub-threshold chunks on one fresh Initiative gate on the crossing batch",
       %{device: device} do
    stub_api(self())
    handshake(device)

    # Chunk 1 CREATES the Initiative with 20 task-adds — one coherent list,
    # it applies with no confirm; the response's lid → id echo moves its
    # count under the real id.
    send_frame(device, tools_call(2, %{"operations" => fresh_import_ops(20)}))

    assert %{"id" => 2, "result" => chunk1} = recv_frame()
    assert chunk1["isError"] == false
    assert_received :applied

    # Chunk 2 is the bulk "rest" by real id: 33 adds bust the per-batch cap,
    # so the tight bound applies — 53 this session crosses it and the gate
    # holds THIS batch for the operator.
    send_frame(
      device,
      tools_call(3, %{
        "operations" => chunk_ops(33, 57),
        "readback" => "Importing the plan's remaining 33 tasks into the same Initiative."
      })
    )

    assert %{
             "method" => "elicitation/create",
             "id" => elicitation_id,
             "params" => %{"message" => message}
           } = recv_frame()

    assert message =~ "remaining 33 tasks"
    refute_received :applied

    send_frame(device, %{
      "jsonrpc" => "2.0",
      "id" => elicitation_id,
      "result" => %{"action" => "accept", "content" => %{"decision" => "apply"}}
    })

    assert %{"id" => 3, "result" => result} = recv_frame()
    assert result["isError"] == false

    {decoded, _rest} = decoded_tool_text(result)
    assert decoded["ok"] == true
    assert_received :applied
  end
end
