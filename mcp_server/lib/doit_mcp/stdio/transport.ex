defmodule DoitMcp.Stdio.Transport do
  @moduledoc """
  Concurrent read/dispatch stdio transport (m03.04 item 2.11.1), replacing
  Anubis 1.6's stock `Anubis.Server.Transport.STDIO` for this adapter.

  The stock transport reads stdin and dispatches each request as a BLOCKING
  `GenServer.call` into the session from the same process: while a tool call
  is in flight nobody reads stdin, so a server-initiated request (the import
  gate's `elicitation/create`) can never receive its answer — the reply sits
  unread in the pipe while the tool waits for it (circular wait). That is why
  the import gate shipped dark.

  Here the reader never blocks on the session:

    * a linked reader process reads stdin line by line and hands each frame
      to this GenServer;
    * requests AND responses are forwarded with `:gen_server.send_request/4`
      — non-blocking; the session's replies come back as info messages,
      matched via `:gen_server.check_response/3` and written to stdout;
    * notifications are cast, exactly like the stock transport;
    * every frame is forwarded from this single process, so the session's
      mailbox sees them in stdin order (per-sender FIFO — same ordering the
      stock serial loop gave), and all stdout writes happen in this process,
      so concurrent replies can't interleave bytes.

  Responses ride the same `{:mcp_request, ...}` path as requests on purpose:
  `Anubis.Server.Session.handle_single_request/4` matches a response to a
  server-initiated request FIRST and processes it immediately even while a
  tool call is in flight, whereas the `{:mcp_response, ...}` cast path defers
  it until the in-flight task completes — which would rebuild the same
  deadlock one level up. The immediate path dispatches
  `DoitMcp.Server.handle_elicitation/3`, whose `DoitMcp.Elicitation.deliver/1`
  resumes the parked tool task.

  On stdin EOF (client hung up) this process stops `:normal`;
  `DoitMcp.TransportWatchdog` monitors it under the registered
  `Anubis.Server.Registry.transport_name/2` and halts the VM.
  """

  @behaviour Anubis.Transport.Behaviour

  use GenServer

  alias Anubis.MCP.Message
  alias Anubis.Server.Registry

  require Logger
  require Message

  @typedoc """
  Options:

    * `:server` — the `Anubis.Server` module (required)
    * `:name` — registered name (default: `Registry.transport_name(server, :stdio)`)
    * `:session` — the session's registered name (default: `Registry.stdio_session_name(server)`)
    * `:io_device` — read/write device (default: `:stdio`; tests inject a fake)
  """
  @type option ::
          {:server, module()}
          | {:name, GenServer.name()}
          | {:session, GenServer.name()}
          | {:io_device, IO.device()}

  @impl Anubis.Transport.Behaviour
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    server = Keyword.fetch!(opts, :server)
    name = Keyword.get(opts, :name, Registry.transport_name(server, :stdio))

    init_arg = %{
      server: server,
      session: Keyword.get(opts, :session, Registry.stdio_session_name(server)),
      io_device: Keyword.get(opts, :io_device, :stdio)
    }

    GenServer.start_link(__MODULE__, init_arg, name: name)
  end

  @impl Anubis.Transport.Behaviour
  def send_message(transport, message, opts) when is_binary(message) do
    GenServer.call(transport, {:send, message}, opts[:timeout] || to_timeout(second: 30))
  end

  @impl Anubis.Transport.Behaviour
  def shutdown(transport), do: GenServer.cast(transport, :shutdown)

  @impl Anubis.Transport.Behaviour
  def supported_protocol_versions, do: :all

  @impl GenServer
  def init(state) do
    # Real stdio: stdout IS the wire — logs must never touch it (config.exs
    # already routes the default handler to stderr; keep the stock
    # transport's belt too) and the device reads UTF-8.
    if state.io_device == :stdio do
      :logger.update_handler_config(:default, :config, %{type: :standard_error})
      _ = :io.setopts(encoding: :utf8)
    end

    Process.flag(:trap_exit, true)

    transport = self()
    reader = spawn_link(fn -> read_loop(state.io_device, transport) end)

    state =
      Map.merge(state, %{
        reader: reader,
        pending: :gen_server.reqids_new(),
        context: %{type: :stdio, env: System.get_env(), pid: System.pid()}
      })

    {:ok, state}
  end

  # The session sends its own outbound frames (elicitation/create, server
  # notifications) through the stock `Anubis.Server.Transport.STDIO`
  # send_message/3 — a stateless GenServer.call wrapper — pointed at THIS
  # process; both it and our own send_message/3 land here. Anubis's
  # Message.encode_* already appends the frame's trailing newline.
  @impl GenServer
  def handle_call({:send, message}, _from, state) do
    IO.write(state.io_device, message)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_cast(:shutdown, state) do
    {:stop, :normal, state}
  end

  @impl GenServer
  def handle_info({:stdin, data}, state) when is_binary(data) do
    case Message.decode(data) do
      {:ok, messages} ->
        {:noreply, Enum.reduce(messages, state, &route/2)}

      {:error, reason} ->
        Logger.error("stdio parse error: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:stdin, :eof}, state) do
    # Client hung up — the session is over. The watchdog monitors this
    # process and turns the stop into a VM halt.
    {:stop, :normal, state}
  end

  def handle_info({:stdin, {:error, reason}}, state) do
    Logger.error("stdio read error: #{inspect(reason)}")
    {:stop, {:shutdown, {:read_error, reason}}, state}
  end

  def handle_info({:EXIT, reader, reason}, %{reader: reader} = state) do
    # :normal follows the reader's own {:stdin, :eof}; anything else means
    # stdin broke without an EOF.
    if reason == :normal do
      {:noreply, state}
    else
      {:stop, {:shutdown, {:reader_exit, reason}}, state}
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(message, state) do
    # Async replies to the {:mcp_request, ...} calls forwarded below.
    case :gen_server.check_response(message, state.pending, true) do
      {{:reply, reply}, _request_id, pending} ->
        write_session_reply(reply, state)
        {:noreply, %{state | pending: pending}}

      {{:error, {reason, _server_ref}}, request_id, pending} ->
        Logger.error("session dropped request #{inspect(request_id)}: #{inspect(reason)}")
        {:noreply, %{state | pending: pending}}

      no_match when no_match in [:no_request, :no_reply] ->
        {:noreply, state}
    end
  end

  # Routing — one clause per JSON-RPC message kind, all from this process so
  # the session sees stdin order.

  defp route(message, state) when Message.is_notification(message) do
    GenServer.cast(state.session, {:mcp_notification, message, state.context})
    state
  end

  # Requests and responses alike; the session replies {:ok, binary} for a
  # request, {:ok, nil} for an absorbed response.
  defp route(message, state) do
    pending =
      :gen_server.send_request(
        state.session,
        {:mcp_request, message, state.context},
        message["id"],
        state.pending
      )

    %{state | pending: pending}
  end

  defp write_session_reply({:ok, response}, state) when is_binary(response) do
    IO.write(state.io_device, response <> "\n")
  end

  defp write_session_reply({:ok, nil}, _state), do: :ok

  defp write_session_reply({:error, reason}, _state) do
    Logger.error("session error: #{inspect(reason)}")
  end

  # Reader — its whole job is to never be the thing that blocks the pipe.

  defp read_loop(device, transport) do
    case IO.read(device, :line) do
      :eof ->
        send(transport, {:stdin, :eof})

      {:error, reason} ->
        send(transport, {:stdin, {:error, reason}})

      data ->
        send(transport, {:stdin, data})
        read_loop(device, transport)
    end
  end
end
