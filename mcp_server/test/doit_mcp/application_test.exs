defmodule DoitMcp.ApplicationTest do
  use ExUnit.Case, async: true

  test "test env starts no children (no transport under ExUnit)" do
    assert DoitMcp.Application.children(:test) == []
  end

  test "DOITLIST_MCP_FRAME_LOGS=off is the only thing that turns capture off" do
    refute DoitMcp.FrameLog.env_enabled?("off")
    assert DoitMcp.FrameLog.env_enabled?(nil)
    assert DoitMcp.FrameLog.env_enabled?("on")
  end

  test "a real run boots the HTTP tree — no lifecycle machinery, no timeout overrides" do
    children = DoitMcp.Application.children(:dev)

    counter = Enum.find_index(children, &(&1 == DoitMcp.ImportGate.Counter))
    registry = Enum.find_index(children, &match?({Registry, _}, &1))
    tasks = Enum.find_index(children, &(&1 == {Task.Supervisor, name: DoitMcp.TaskSupervisor}))
    sessions = Enum.find_index(children, &(&1 == DoitMcp.TokenRecovery.Sessions))
    frame_log = Enum.find_index(children, &(&1 == DoitMcp.FrameLog))
    server = Enum.find_index(children, &match?({DoitMcp.Server, _}, &1))
    bandit = Enum.find_index(children, &match?({Bandit, _}, &1))

    assert counter, "expected DoitMcp.ImportGate.Counter in children"
    assert registry, "expected the elicitation waiter Registry in children"
    assert tasks, "expected the out-of-band waiters' Task.Supervisor in children"
    assert sessions, "expected DoitMcp.TokenRecovery.Sessions in children"
    assert frame_log, "expected DoitMcp.FrameLog in children"
    assert server, "expected the DoitMcp.Server transport tree in children"
    assert bandit, "expected a Bandit listener in children"

    # The gate's counter — and the elicitation/recovery state (m03.04 item
    # 23.3, the waiters' supervisor with it, 2.3.3) — must never race a tool
    # call, and the listener must not accept requests before the tree can
    # take them. Frame capture (23.5) joins that rule: no session's first
    # frame outruns it.
    assert counter < server
    assert registry < server
    assert tasks < server
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

    # The wrapper plug (m03.04 2.2.1.3): elicitation answers reroute to
    # the immediate session call path; everything else is the stock plug.
    assert {DoitMcp.Http.Plug, server: DoitMcp.Server} = bandit_opts[:plug]
  end
end
