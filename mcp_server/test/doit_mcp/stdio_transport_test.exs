defmodule DoitMcp.StdioTransportTest.FakeIO do
  @moduledoc """
  Minimal Erlang I/O server standing in for the OS pipe: the test feeds
  stdin lines (or EOF) and receives everything written to stdout as
  `{:stdout, binary}` messages.

  Implements just what the transport uses — `{:get_line, ...}` for the
  reader, parking the request while no line is queued (a real pipe blocks;
  StringIO's instant `:eof` on a drained buffer is exactly what makes it
  unusable for "the answer arrives later" scenarios) — and
  `{:put_chars, ...}` for writes.
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

      # The owning test is gone (its :normal exit doesn't propagate down the
      # link). Don't just exit: teardown races us — if the device dies before
      # the transport's reader, the reader sees {:error, :terminated} and the
      # transport logs a spurious error. Serve :eof until everyone's gone.
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

defmodule DoitMcp.StdioTransportTest do
  # async: false — boots the production stdio tree under its real global
  # registry names and swaps global app env.
  use ExUnit.Case, async: false

  alias Anubis.Server.Registry
  alias DoitMcp.ImportGate
  alias DoitMcp.StdioTransportTest.FakeIO

  # Session/transport lifecycles log; keep test output clean.
  @moduletag :capture_log

  @threshold ImportGate.threshold()

  # End-to-end over wire-level JSON-RPC frames against the REAL production
  # tree — DoitMcp.Stdio.Supervisor, real session, real transport — with only
  # the OS pipe faked. This is the proof m03.03 item 5.11.1 exists for: the
  # stock serial transport could not read the operator's elicitation answer
  # while the gated tools/call was in flight.

  setup do
    # Determinism against any ambient DOITLIST_IMPORT_GATE in the container.
    Application.put_env(:doit_mcp, :import_gate_enabled, true)

    # The tool task runs under the session's Task.Supervisor — outside the
    # test's $callers chain — so Req.Test's per-process stub ownership can't
    # reach it. Tests that apply for real inject a plain plug fun instead
    # (DoitMcp.Client merges the :req_options app env).
    previous_req = Application.fetch_env(:doit_mcp, :req_options)

    on_exit(fn ->
      Application.delete_env(:doit_mcp, :import_gate_enabled)

      case previous_req do
        {:ok, value} -> Application.put_env(:doit_mcp, :req_options, value)
        :error -> Application.delete_env(:doit_mcp, :req_options)
      end
    end)

    device = FakeIO.open(self())

    start_supervised!(
      {DoitMcp.Stdio.Supervisor, io_device: device, session_idle_timeout: to_timeout(minute: 10)}
    )

    {:ok, device: device}
  end

  defp stub_http(fun), do: Application.put_env(:doit_mcp, :req_options, plug: fun)

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
        "clientInfo" => %{"name" => "transport-test", "version" => "1.0"},
        "capabilities" => %{"elicitation" => %{}}
      }
    })

    assert %{"id" => 1, "result" => %{"serverInfo" => _}} = recv_frame()

    send_frame(device, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
    :ok
  end

  defp gated_call(id) do
    operations =
      [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
        for i <- 1..(@threshold + 1) do
          %{
            "op" => "add",
            "type" => "task",
            "lid" => "t#{i}",
            "data" => %{"initiative_lid" => "i", "title" => "task #{i}"}
          }
        end

    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{
        "name" => "apply_operations",
        "arguments" => %{
          "operations" => operations,
          "readback" => "Importing PLAN.md as #{@threshold + 1} tasks under one new Initiative.",
          "assumptions" => ["Depth taken from markdown heading levels"]
        }
      }
    }
  end

  defp decoded_tool_text(result) do
    assert [%{"type" => "text", "text" => text} | rest] = result["content"]
    {Jason.decode!(text), rest}
  end

  test "an elicitation answer arriving while the gated call is in flight completes it",
       %{device: device} do
    handshake(device)

    send_frame(device, gated_call(2))

    # The server-initiated elicitation/create goes OUT while the tools/call
    # is still unanswered — the stock serial transport never got this far.
    assert %{
             "method" => "elicitation/create",
             "id" => elicitation_id,
             "params" => %{"message" => message}
           } = recv_frame()

    assert message =~ "Importing PLAN.md"

    # The reader must still be free to carry this answer INTO the server
    # while the call is in flight — this frame is the 5.11.1 acceptance.
    send_frame(device, %{
      "jsonrpc" => "2.0",
      "id" => elicitation_id,
      "result" => %{
        "action" => "accept",
        "content" => %{"confirm" => false, "corrections" => "Milestones as top-level tasks"}
      }
    })

    assert %{"id" => 2, "result" => result} = recv_frame()
    assert result["isError"] == true

    {decoded, _rest} = decoded_tool_text(result)
    assert decoded["applied"] == false
    assert decoded["corrections"] == "Milestones as top-level tasks"
  end

  test "operator confirm applies the batch through the real transport", %{device: device} do
    stub_http(fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/operations"
      Req.Test.json(conn, %{"results" => []})
    end)

    handshake(device)
    send_frame(device, gated_call(2))

    assert %{"method" => "elicitation/create", "id" => elicitation_id} = recv_frame()

    send_frame(device, %{
      "jsonrpc" => "2.0",
      "id" => elicitation_id,
      "result" => %{"action" => "accept", "content" => %{"confirm" => true}}
    })

    assert %{"id" => 2, "result" => result} = recv_frame()
    assert result["isError"] == false

    {decoded, rest} = decoded_tool_text(result)
    assert decoded["ok"] == true
    assert [%{"type" => "text", "text" => note}] = rest
    assert note =~ "ai_knobs"
  end

  test "an ungated call round-trips while nothing is in flight", %{device: device} do
    stub_http(fn conn ->
      Req.Test.json(conn, %{"results" => []})
    end)

    handshake(device)

    send_frame(device, %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{
        "name" => "apply_operations",
        "arguments" => %{
          "operations" => [
            %{
              "op" => "add",
              "type" => "task",
              "data" => %{"initiative_id" => 7, "title" => "one"}
            }
          ]
        }
      }
    })

    assert %{"id" => 2, "result" => result} = recv_frame()
    assert result["isError"] == false
  end

  test "client EOF stops the transport normally and trips the watchdog's halt",
       %{device: device} do
    test_pid = self()
    transport = Process.whereis(Registry.transport_name(DoitMcp.Server, :stdio))
    assert is_pid(transport)

    start_supervised!(
      {DoitMcp.TransportWatchdog,
       transport: Registry.transport_name(DoitMcp.Server, :stdio),
       halt: fn code -> send(test_pid, {:halted, code}) end}
    )

    ref = Process.monitor(transport)
    FakeIO.feed_eof(device)

    assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, 5_000
    assert_receive {:halted, 0}, 5_000
  end
end
