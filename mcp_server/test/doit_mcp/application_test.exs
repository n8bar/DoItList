defmodule DoitMcp.ApplicationTest do
  use ExUnit.Case, async: true

  test "test env starts no children (no stdio transport under ExUnit)" do
    assert DoitMcp.Application.children(:test) == []
  end

  test "real runs wire the transport watchdog after the server" do
    children = DoitMcp.Application.children(:dev)

    server = Enum.find_index(children, &match?({DoitMcp.Server, _}, &1))
    watchdog = Enum.find_index(children, &match?({DoitMcp.TransportWatchdog, _}, &1))

    assert server, "expected DoitMcp.Server in children"
    assert watchdog, "expected DoitMcp.TransportWatchdog in children"

    # The watchdog resolves the transport by registered name, so the server
    # (which registers it) must already be up.
    assert server < watchdog
  end
end
