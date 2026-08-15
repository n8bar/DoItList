defmodule DoitMcp.Http.Plug do
  @moduledoc """
  The adapter's front door on streamable HTTP (m03.04 2.5.3): Anubis's
  stock `Anubis.Server.Transport.StreamableHTTP.Plug` for every request
  shape but ONE — a client POST carrying a JSON-RPC *response or error* (the
  answer to a server-initiated request, e.g. an elicitation form) is
  delivered to the session via the immediate `{:mcp_request, ...}` call path
  instead of the stock plug's `{:mcp_response, ...}` cast.

  The reroute is what makes a mid-call elicitation possible at all:
  `Anubis.Server.Session.handle_single_request/4` matches a response to a
  server-initiated request FIRST and processes it immediately even while a
  tool call is in flight, whereas the cast path defers every `mcp_response`
  until the in-flight task completes — so a tool call parked on an
  elicitation answer would deadlock until its timeout, because the answer it
  waits for sits in the deferred queue behind it.

  Everything else — requests, notifications, GET (the standalone SSE
  stream), DELETE, unparseable bodies — flows to the stock plug untouched:
  the body is read here once and handed over via `body_params`, which the
  stock plug accepts in place of its own read.

  Both frame-carrying shapes — a POST and the standalone GET stream — also
  get `DoitMcp.Http.FrameTap` installed on the way in, which is what puts
  the session's frames in its own log (m03.04 2.5.5). The well-known
  metadata route and DELETE carry no frames, so neither is tapped.
  """

  @behaviour Plug

  import Plug.Conn

  alias Anubis.MCP.Error
  alias Anubis.MCP.ID
  alias Anubis.MCP.Message
  alias Anubis.Server.Registry
  alias Anubis.Server.Transport.StreamableHTTP
  alias DoitMcp.Http.FrameTap

  require Message

  @well_known "/.well-known/oauth-protected-resource"

  @impl Plug
  def init(opts) do
    %{
      server: Keyword.fetch!(opts, :server),
      session_header: Keyword.get(opts, :session_header, "mcp-session-id"),
      timeout: Keyword.get(opts, :request_timeout, 30_000),
      stock: StreamableHTTP.Plug.init(opts)
    }
  end

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: path} = conn, opts)
      when path != @well_known do
    case read_body_once(conn, opts) do
      {:ok, body, conn} ->
        conn = FrameTap.install(conn, opts.session_header, body)

        case classify(body) do
          {:response, message} -> deliver_response(conn, message, opts)
          :other -> stock(%{conn | body_params: body}, opts)
        end

      {:error, reason} ->
        # Mirrors the stock plug's failed-read answer.
        send_jsonrpc_error(conn, Error.protocol(:internal_error, %{reason: reason}))
    end
  end

  def call(%Plug.Conn{method: "GET", request_path: path} = conn, opts)
      when path != @well_known do
    conn
    |> FrameTap.install(opts.session_header, nil)
    |> stock(opts)
  end

  def call(conn, opts), do: stock(conn, opts)

  defp stock(conn, opts), do: StreamableHTTP.Plug.call(conn, opts.stock)

  defp read_body_once(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, opts) do
    read_body(conn, read_timeout: opts.timeout)
  end

  defp read_body_once(%Plug.Conn{body_params: body} = conn, _opts), do: {:ok, body, conn}

  # Exactly one decoded message that is a response or an error reroutes;
  # anything else — a request, a notification, a batch, junk — is the stock
  # plug's business (including producing the right parse errors).
  defp classify(body) when is_binary(body) do
    case Message.decode(body) do
      {:ok, [message]} ->
        if Message.is_response(message) or Message.is_error(message),
          do: {:response, message},
          else: :other

      _ ->
        :other
    end
  end

  defp classify(_already_parsed), do: :other

  defp deliver_response(conn, message, opts) do
    with [session_id] when session_id != "" <- get_req_header(conn, opts.session_header),
         {:ok, session} <- lookup_session(opts.server, session_id) do
      # The session replies {:ok, nil} for an absorbed response and an error
      # for a stale/unknown response id — both are acknowledged 202 exactly
      # like the stock cast path, which could not report delivery either.
      _ = call_session(session, message, request_context(conn), opts.timeout)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(202, "{}")
    else
      _ -> session_not_found(conn)
    end
  end

  defp call_session(session, message, context, timeout) do
    GenServer.call(session, {:mcp_request, message, context}, timeout)
  catch
    :exit, reason -> {:error, reason}
  end

  defp lookup_session(server, session_id) do
    registry_mod = Anubis.Server.Supervisor.get_session_config(server).registry_mod
    registry_mod.lookup_session(Registry.registry_name(server), session_id)
  end

  # Same context shape the stock plug builds for a POST.
  defp request_context(conn) do
    %{
      assigns: conn.assigns,
      type: :http,
      req_headers: conn.req_headers,
      query_params: query_params(conn),
      remote_ip: conn.remote_ip,
      scheme: conn.scheme,
      host: conn.host,
      port: conn.port,
      request_path: conn.request_path,
      auth: nil
    }
  end

  defp query_params(conn) do
    case conn.query_params do
      %Plug.Conn.Unfetched{} -> nil
      params -> params
    end
  end

  # The stock plug's 404 for a response against a session this tree never
  # saw, byte-compatible with its send_error/3.
  defp session_not_found(conn) do
    data = %{data: %{message: "Session not found", http_status: 404}}

    {:ok, body} =
      Error.to_json_rpc(Error.protocol(:invalid_request, data), ID.generate_error_id())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, body)
  end

  defp send_jsonrpc_error(conn, %Error{} = error) do
    {:ok, body} = Error.to_json_rpc(error, ID.generate_error_id())

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, body)
  end
end
