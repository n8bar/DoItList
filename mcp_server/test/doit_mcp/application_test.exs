defmodule DoitMcp.ApplicationTest do
  use ExUnit.Case, async: true

  test "test env starts no children (no stdio transport under ExUnit)" do
    assert DoitMcp.Application.children(:test) == []
  end

  test "real runs wire the transport watchdog after the stdio tree" do
    children = DoitMcp.Application.children(:dev)

    counter = Enum.find_index(children, &(&1 == DoitMcp.ImportGate.Counter))
    stdio = Enum.find_index(children, &match?({DoitMcp.Stdio.Supervisor, _}, &1))
    watchdog = Enum.find_index(children, &match?({DoitMcp.TransportWatchdog, _}, &1))

    assert stdio, "expected DoitMcp.Stdio.Supervisor in children"
    assert watchdog, "expected DoitMcp.TransportWatchdog in children"

    # The gate's session counter must never race a tool call.
    assert counter, "expected DoitMcp.ImportGate.Counter in children"
    assert counter < stdio

    # The watchdog resolves the transport by registered name, so the stdio
    # tree (which registers it) must already be up.
    assert stdio < watchdog
  end

  test "real runs pin the stdio session open past anubis's 30-minute idle default" do
    {DoitMcp.Stdio.Supervisor, opts} =
      Enum.find(DoitMcp.Application.children(:dev), &match?({DoitMcp.Stdio.Supervisor, _}, &1))

    timeout = Keyword.fetch!(opts, :session_idle_timeout)

    # Big enough to outlive any real session, small enough for
    # Process.send_after's timer ceiling (4_294_967_295 ms ≈ 49.7 days).
    assert timeout >= to_timeout(day: 30)
    assert timeout <= 4_294_967_295
  end
end
