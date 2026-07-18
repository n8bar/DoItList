defmodule DoitMcp.Stdio.Supervisor do
  @moduledoc """
  The adapter's stdio tree (m03.04 item 2.11.1): the anubis Session plus
  `DoitMcp.Stdio.Transport`, assembled by hand.

  Anubis 1.6's `Anubis.Server.Supervisor` hardwires the transport module
  (`parse_transport_child/2` knows only `:stdio`/`:streamable_http`/`:sse`),
  so a custom transport can't be configured through
  `{DoitMcp.Server, transport: :stdio}`. This mirrors its
  `build_stdio_children/6` — the same registered names from
  `Anubis.Server.Registry` (the watchdog and `DoitMcp.Elicitation` resolve
  processes through them), the same Task.Supervisor, the same Session options
  — swapping only the transport module. (The task store is omitted: this
  server never declares the `tasks` capability, so the session can't take a
  task-augmented call.)

  The Session's `transport:` option stays the stock STDIO *layer* because the
  session validates the layer against a fixed whitelist and only ever calls
  `layer.send_message/3` — a stateless `GenServer.call(name, {:send, msg})`
  wrapper — so pointing its `name:` at our transport routes every outbound
  frame here without patching the dep.

  Options: `:session_idle_timeout` (the caller pins it near the timer
  ceiling — see `DoitMcp.Application`), `:io_device` (tests inject a fake
  device; defaults to `:stdio`).
  """

  use Supervisor

  alias Anubis.Server.Registry

  @server DoitMcp.Server

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    task_supervisor = Registry.task_supervisor_name(@server)
    transport_name = Registry.transport_name(@server, :stdio)

    session_opts =
      [
        session_id: "stdio",
        server_module: @server,
        name: Registry.stdio_session_name(@server),
        transport: [layer: Anubis.Server.Transport.STDIO, name: transport_name],
        task_supervisor: task_supervisor
      ] ++ Keyword.take(opts, [:session_idle_timeout])

    transport_opts = [
      server: @server,
      name: transport_name,
      io_device: Keyword.get(opts, :io_device, :stdio)
    ]

    children = [
      {Task.Supervisor, name: task_supervisor},
      {Anubis.Server.Session, session_opts},
      # :transient — stopping :normal on client EOF is the transport's job
      # (the watchdog turns it into a VM halt), not something to restart
      # into another immediate EOF.
      Supervisor.child_spec({DoitMcp.Stdio.Transport, transport_opts}, restart: :transient)
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
