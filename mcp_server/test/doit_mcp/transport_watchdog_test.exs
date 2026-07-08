defmodule DoitMcp.TransportWatchdogTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Transport.STDIO
  alias DoitMcp.TransportWatchdog

  # The real anubis transport logs its eof/terminate lifecycle; keep test
  # output clean.
  @moduletag :capture_log

  test "calls halt(0) when the stdio transport stops on EOF" do
    test_pid = self()

    # A real anubis stdio transport reading a drained StringIO: it hits EOF
    # immediately and does {:stop, :normal, ...} — exactly the client
    # disconnect that leaked zombie adapters. :temporary so the test
    # supervisor doesn't restart it into the same EOF over and over.
    {:ok, io} = StringIO.open("")

    transport =
      start_supervised!(
        Supervisor.child_spec(
          {STDIO, server: DoitMcp.Server, io_device: io},
          restart: :temporary
        )
      )

    start_supervised!(
      {TransportWatchdog,
       transport: transport, halt: fn code -> send(test_pid, {:halted, code}) end}
    )

    assert_receive {:halted, 0}
  end

  test "calls halt(0) when the transport is already gone at startup" do
    test_pid = self()

    start_supervised!(
      {TransportWatchdog,
       transport: :"#{__MODULE__}.NoSuchTransport",
       halt: fn code -> send(test_pid, {:halted, code}) end}
    )

    assert_receive {:halted, 0}
  end
end
