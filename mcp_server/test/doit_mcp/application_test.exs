defmodule DoitMcp.ApplicationTest do
  use ExUnit.Case, async: true

  test "test env starts no children (no stdio transport under ExUnit)" do
    assert DoitMcp.Application.children(:test) == []
    assert DoitMcp.Application.children(:test, :http) == []
  end

  test "DOITLIST_MCP_TRANSPORT=http selects HTTP mode; anything else keeps stdio" do
    assert DoitMcp.Application.transport_mode("http") == :http
    assert DoitMcp.Application.transport_mode("stdio") == :stdio
    assert DoitMcp.Application.transport_mode(nil) == :stdio
  end

  test "DOITLIST_MCP_FRAME_LOGS=off is the only thing that turns capture off" do
    refute DoitMcp.FrameLog.env_enabled?("off")
    assert DoitMcp.FrameLog.env_enabled?(nil)
    assert DoitMcp.FrameLog.env_enabled?("on")
  end

  test "the default mode is stdio, so unset env keeps today's tree" do
    assert DoitMcp.Application.children(:dev) == DoitMcp.Application.children(:dev, :stdio)
  end

  test "http mode boots the HTTP tree — no stdio tree, no watchdog, no timeout overrides" do
    children = DoitMcp.Application.children(:dev, :http)

    # The stdio lifecycle machinery has no business on HTTP: sessions are
    # per-client processes with anubis's stock 30-minute idle expiry
    # (m03.04 item 23.4), not one VM pinned open per connect.
    refute Enum.any?(children, &match?({DoitMcp.Stdio.Supervisor, _}, &1))
    refute Enum.any?(children, &match?({DoitMcp.TransportWatchdog, _}, &1))

    counter = Enum.find_index(children, &(&1 == DoitMcp.ImportGate.Counter))
    registry = Enum.find_index(children, &match?({Registry, _}, &1))
    sessions = Enum.find_index(children, &(&1 == DoitMcp.TokenRecovery.Sessions))
    frame_log = Enum.find_index(children, &(&1 == DoitMcp.FrameLog))
    server = Enum.find_index(children, &match?({DoitMcp.Server, _}, &1))
    bandit = Enum.find_index(children, &match?({Bandit, _}, &1))

    assert counter, "expected DoitMcp.ImportGate.Counter in children"
    assert registry, "expected the elicitation waiter Registry in children"
    assert sessions, "expected DoitMcp.TokenRecovery.Sessions in children"
    assert frame_log, "expected DoitMcp.FrameLog in children"
    assert server, "expected the DoitMcp.Server transport tree in children"
    assert bandit, "expected a Bandit listener in children"

    # Same rule as stdio: the gate's counter — and the elicitation/recovery
    # state (m03.04 item 23.3) — must never race a tool call, and the
    # listener must not accept requests before the tree can take them. Frame
    # capture (23.5) joins that rule: no session's first frame outruns it.
    assert counter < server
    assert registry < server
    assert sessions < server
    assert frame_log < server
    assert server < bandit

    {DoitMcp.Server, server_opts} = Enum.at(children, server)

    # Only the transport is configured: no :session_idle_timeout (stock
    # 30-minute expiry stands) and no substantive-idle window.
    assert Keyword.keys(server_opts) == [:transport]
    assert {:streamable_http, _} = server_opts[:transport]

    {Bandit, bandit_opts} = Enum.at(children, bandit)
    assert bandit_opts[:port] == 4004
    assert bandit_opts[:ip] == {0, 0, 0, 0}

    # The wrapper plug (m03.04 item 23.3): elicitation answers reroute to
    # the immediate session call path; everything else is the stock plug.
    assert {DoitMcp.Http.Plug, server: DoitMcp.Server} = bandit_opts[:plug]
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

    # Elicitation waiters key on the session process on stdio too (23.3).
    registry = Enum.find_index(children, &match?({Registry, _}, &1))
    assert registry, "expected the elicitation waiter Registry in children"
    assert registry < stdio

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

  test "real runs reap the transport after 2 hours without substantive traffic" do
    {DoitMcp.Stdio.Supervisor, opts} =
      Enum.find(DoitMcp.Application.children(:dev), &match?({DoitMcp.Stdio.Supervisor, _}, &1))

    # Deliberately distinct from :session_idle_timeout (sidelined at 49 days,
    # above): this window counts only non-ping frames, so a pinging-but-
    # abandoned client still gets reaped (m03.04 item 22).
    assert Keyword.fetch!(opts, :substantive_idle_timeout) == to_timeout(hour: 2)
  end
end
