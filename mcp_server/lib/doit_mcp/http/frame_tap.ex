defmodule DoitMcp.Http.FrameTap do
  @moduledoc """
  The connection-side half of the HTTP frame capture (m03.04 2.5.5):
  every JSON-RPC frame this service reads or writes on a connection, handed
  to `DoitMcp.FrameLog` tagged with its session.

  Inbound is ours already — `DoitMcp.Http.Plug` reads every POST body. The
  outbound leg is not: the stock anubis plug writes tool responses and the
  session's server-to-client stream itself, and in two shapes — a JSON body
  on the POST, or SSE chunks (a spec-compliant client accepts
  `text/event-stream`, so its POST answers stream too, and elicitations
  always ride the standalone GET stream). Both shapes pass through the
  conn's Plug adapter, so that is the seam: this module wraps it, delegating
  every callback to the real adapter and copying what goes by.

  The adapter PAYLOAD is left exactly as the web server built it (bandit
  reads its own struct off the conn after the plug returns); the wrapped
  module and this request's capture state ride the process dictionary
  instead — per request process, like `DoitMcp.RequestSession`.

  Capture never breaks serving: the real adapter is called first and its
  result returned untouched, and every capture step is swallowed on failure.

  One gap follows from that shape: a request that arrives before its session
  has an id (`initialize`) is held until the answer names the session, so a
  request that never answers at all — the process killed mid-flight — takes
  its inbound line with it. Every other frame is written as it passes.
  """

  @behaviour Plug.Conn.Adapter

  alias DoitMcp.FrameLog

  @key :doit_mcp_frame_tap

  @doc """
  Capture this connection's frames. The inbound body is recorded now, or
  held until the answer when the session id is only assigned there (an
  `initialize`). Returns the conn unchanged when capture is off.
  """
  @spec install(Plug.Conn.t(), String.t(), binary() | nil) :: Plug.Conn.t()
  def install(conn, session_header, body) do
    if FrameLog.enabled?() do
      {module, payload} = conn.adapter

      put_state(%{
        module: module,
        session_header: session_header,
        session_id: request_session_id(conn, session_header),
        pending: []
      })

      safely(fn -> capture_in(body) end)
      %{conn | adapter: {__MODULE__, payload}}
    else
      conn
    end
  end

  @impl Plug.Conn.Adapter
  def send_resp(payload, status, headers, body) do
    result = wrapped().send_resp(payload, status, headers, body)
    safely(fn -> capture_out(headers, body) end)
    result
  end

  @impl Plug.Conn.Adapter
  def send_chunked(payload, status, headers) do
    result = wrapped().send_chunked(payload, status, headers)
    # A streamed answer carries the session id in its headers too; flush
    # whatever inbound frame was waiting for it. The frames themselves
    # arrive as chunks below.
    safely(fn -> capture_out(headers, nil) end)
    result
  end

  @impl Plug.Conn.Adapter
  def chunk(payload, body) do
    result = wrapped().chunk(payload, body)
    safely(fn -> capture_sse(body) end)
    result
  end

  @impl Plug.Conn.Adapter
  def send_file(payload, status, headers, path, offset, length) do
    wrapped().send_file(payload, status, headers, path, offset, length)
  end

  @impl Plug.Conn.Adapter
  def read_req_body(payload, opts), do: wrapped().read_req_body(payload, opts)

  @impl Plug.Conn.Adapter
  def inform(payload, status, headers), do: wrapped().inform(payload, status, headers)

  @impl Plug.Conn.Adapter
  def upgrade(payload, protocol, opts), do: wrapped().upgrade(payload, protocol, opts)

  @impl Plug.Conn.Adapter
  def push(payload, path, headers), do: wrapped().push(payload, path, headers)

  @impl Plug.Conn.Adapter
  def get_peer_data(payload), do: wrapped().get_peer_data(payload)

  @impl Plug.Conn.Adapter
  def get_sock_data(payload), do: wrapped().get_sock_data(payload)

  @impl Plug.Conn.Adapter
  def get_ssl_data(payload), do: wrapped().get_ssl_data(payload)

  @impl Plug.Conn.Adapter
  def get_http_protocol(payload), do: wrapped().get_http_protocol(payload)

  defp capture_in(nil), do: :ok

  defp capture_in(body) when is_binary(body) do
    state = state()

    case state.session_id do
      nil -> put_state(%{state | pending: state.pending ++ [decode(body)]})
      session_id -> FrameLog.capture(session_id, :in, decode(body))
    end

    :ok
  end

  defp capture_in(_already_parsed), do: :ok

  defp capture_out(headers, body) do
    state = resolve_session(headers)
    Enum.each(state.pending, &FrameLog.capture(state.session_id, :in, &1))
    put_state(%{state | pending: []})

    if is_binary(body) and body != "" do
      FrameLog.capture(state.session_id, :out, decode(body))
    end

    :ok
  end

  # An SSE chunk carries the frame on its `data:` line (anubis writes one
  # line per event); keepalives and priming events carry none.
  defp capture_sse(body) do
    session_id = state().session_id

    for line <- String.split(IO.iodata_to_binary(body), "\n"),
        String.starts_with?(line, "data: "),
        payload = String.trim_leading(line, "data: "),
        payload != "" do
      FrameLog.capture(session_id, :out, decode(payload))
    end

    :ok
  end

  # The frame as it went over the wire. Anything that is not JSON is kept
  # verbatim — a malformed body is exactly what the host frame logs existed
  # to show.
  defp decode(body) do
    case JSON.decode(body) do
      {:ok, frame} -> frame
      {:error, _reason} -> %{"unparsed" => body}
    end
  end

  # The session id of a request that arrived without one is assigned in the
  # answer's headers (`initialize`); remember it for this request's chunks.
  defp resolve_session(headers) do
    case state() do
      %{session_id: nil} = state ->
        put_state(%{state | session_id: header(headers, state.session_header)})

      state ->
        state
    end
  end

  defp request_session_id(conn, session_header) do
    case Plug.Conn.get_req_header(conn, session_header) do
      [session_id | _rest] when session_id != "" -> session_id
      _none -> nil
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      String.downcase(key) == name and value != "" and value
    end)
  end

  defp safely(fun) do
    fun.()
  rescue
    _error -> :ok
  catch
    _kind, _value -> :ok
  end

  defp wrapped, do: state().module

  defp state, do: Process.get(@key)

  defp put_state(state) do
    Process.put(@key, state)
    state
  end
end
