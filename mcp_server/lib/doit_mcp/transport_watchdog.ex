defmodule DoitMcp.TransportWatchdog do
  @moduledoc """
  Exits the VM when the stdio transport stops.

  The adapter runs under `mix run --no-halt`, so the BEAM outlives the MCP
  session: on client disconnect the anubis transport reads EOF and stops its
  own GenServer, but nothing stops the VM — every session leaked a zombie
  adapter in the container. This monitors the transport and turns "transport
  stopped" into "VM exits".
  """

  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    transport = Keyword.fetch!(opts, :transport)
    # Injectable for tests. System.stop/1 shuts down cleanly (stops
    # applications, flushes stdio) and exits even under --no-halt.
    halt = Keyword.get(opts, :halt, &System.stop/1)

    case GenServer.whereis(transport) do
      # Already gone — stopped before we got to monitor it. Same outcome.
      nil -> halt.(0)
      pid -> Process.monitor(pid)
    end

    {:ok, %{halt: halt}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Any transport exit — EOF, crash, shutdown — means the session is over.
    state.halt.(0)
    {:noreply, state}
  end
end
