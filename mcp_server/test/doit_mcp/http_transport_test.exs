defmodule DoitMcp.HttpTransportTest do
  # async: false — boots the anubis HTTP tree under its real global registry
  # names and swaps the global :req_options app env.
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias Anubis.Server.Transport.StreamableHTTP

  # Session/transport lifecycles log; keep test output clean.
  @moduletag :capture_log

  # The resident HTTP transport (m03.04 2.5): per-session bearer tokens
  # on the API path (23.2) and anubis's stock session hygiene (23.4), driven
  # through the real tree — registry, dynamic session supervisor, transport —
  # via the same plug Bandit serves, plus one smoke over a real listener.

  setup do
    previous_req = Application.fetch_env(:doit_mcp, :req_options)

    on_exit(fn ->
      case previous_req do
        {:ok, value} -> Application.put_env(:doit_mcp, :req_options, value)
        :error -> Application.delete_env(:doit_mcp, :req_options)
      end
    end)

    start_supervised!({DoitMcp.Server, transport: {:streamable_http, start: true}})
    :ok
  end

  # Computed per call, not a module attribute: 1.10's Plug.init/1 embeds a
  # local-function capture (the default :subscriber_metadata), which cannot
  # be escaped into a compile-time attribute.
  defp plug_opts, do: StreamableHTTP.Plug.init(server: DoitMcp.Server)

  # The API stub reports each request's Authorization header to the test —
  # the request task runs outside the test's $callers chain, so Req.Test's
  # per-process stub ownership can't reach it; inject a plain plug fun
  # (DoitMcp.Client merges the :req_options app env).
  defp stub_api(test_pid) do
    Application.put_env(:doit_mcp, :req_options,
      plug: fn conn ->
        send(test_pid, {:api_call, Plug.Conn.get_req_header(conn, "authorization")})
        Req.Test.json(conn, %{"data" => %{"id" => 1, "email" => "op@example.com"}})
      end
    )
  end

  defp post_frame(message, headers) do
    conn =
      conn(:post, "/", Jason.encode!(message))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    |> StreamableHTTP.Plug.call(plug_opts())
  end

  defp initialize_message(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "http-transport-test", "version" => "1.0"},
        "capabilities" => %{}
      }
    }
  end

  # Full handshake through the plug; returns the server-assigned session id.
  defp handshake(headers) do
    conn = post_frame(initialize_message(1), headers)
    assert conn.status == 200
    assert %{"result" => %{"serverInfo" => _}} = Jason.decode!(conn.resp_body)

    [session_id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    conn =
      post_frame(
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        [{"mcp-session-id", session_id} | headers]
      )

    assert conn.status == 202
    session_id
  end

  defp get_me_call(id), do: tools_call(id, "get_me", %{})

  defp tools_call(id, name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
  end

  defp tool_result(conn) do
    assert conn.status == 200
    assert %{"result" => result} = Jason.decode!(conn.resp_body)
    assert [%{"type" => "text", "text" => text} | _] = result["content"]
    {result["isError"], text}
  end

  test "concurrent sessions call the API with their own bearer tokens" do
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    beta = [{"authorization", "Bearer token-beta"}]

    session_a = handshake(alpha)
    session_b = handshake(beta)

    # Both sessions live at once; each tool call must ride its own header.
    conn = post_frame(get_me_call(2), [{"mcp-session-id", session_a} | alpha])
    assert {false, _text} = tool_result(conn)
    assert_received {:api_call, ["Bearer token-alpha"]}

    conn = post_frame(get_me_call(2), [{"mcp-session-id", session_b} | beta])
    assert {false, _text} = tool_result(conn)
    assert_received {:api_call, ["Bearer token-beta"]}
  end

  test "a session without a bearer header gets the dead-token guidance, never the env token" do
    # test_helper sets DOITLIST_API_TOKEN — an API token lying around in
    # the VM's environment. It must not leak into a session that presented
    # nothing.
    stub_api(self())

    session = handshake([])
    conn = post_frame(get_me_call(2), [{"mcp-session-id", session}])

    # Same 401-driven guidance a dead token surfaces (m03.04 2.12) —
    # and no API round trip at all: there is no credential to send.
    assert {true, text} = tool_result(conn)
    assert text =~ "(401)"
    assert text =~ "rejected this session's API token"
    refute_received {:api_call, _headers}
  end

  test "an unknown or expired session id lets a live client carry on cleanly" do
    # A request against a session this tree never saw (same as one whose
    # 30-minute idle expiry fired): anubis recreates the session under the
    # given id, auto-initializes it, and serves the request.
    conn =
      post_frame(%{"jsonrpc" => "2.0", "id" => 9, "method" => "tools/list"}, [
        {"mcp-session-id", "expired-session-id"}
      ])

    assert conn.status == 200
    assert %{"result" => %{"tools" => tools}} = Jason.decode!(conn.resp_body)
    assert Enum.any?(tools, &(&1["name"] == "get_me"))

    # The recreated session runs on the stock idle default — the no-override
    # proof at runtime (m03.04 2.5.4).
    registry = Anubis.Server.Registry.registry_name(DoitMcp.Server)

    {:ok, session_pid} =
      Anubis.Server.Registry.Local.lookup_session(registry, "expired-session-id")

    assert :sys.get_state(session_pid).session_idle_timeout == to_timeout(minute: 30)

    # A notification can't recreate a session — the protocol error tells the
    # client the session is gone, and its next request re-initializes.
    conn =
      post_frame(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, [
        {"mcp-session-id", "never-seen-session-id"}
      ])

    assert conn.status == 404
  end

  test "initialize → initialized → tools/list over a real HTTP listener" do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {StreamableHTTP.Plug, server: DoitMcp.Server},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    req =
      Req.new(
        base_url: "http://127.0.0.1:#{port}",
        headers: [{"accept", "application/json"}],
        retry: false
      )

    resp = Req.post!(req, url: "/", json: initialize_message(1))
    assert resp.status == 200
    assert %{"result" => %{"serverInfo" => %{"name" => "doitlist"}}} = resp.body
    [session_id] = Req.Response.get_header(resp, "mcp-session-id")

    resp =
      Req.post!(req,
        url: "/",
        json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        headers: [{"mcp-session-id", session_id}]
      )

    assert resp.status == 202

    resp =
      Req.post!(req,
        url: "/",
        json: %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"},
        headers: [{"mcp-session-id", session_id}]
      )

    assert resp.status == 200
    assert %{"result" => %{"tools" => tools}} = resp.body
    names = Enum.map(tools, & &1["name"])
    assert "get_me" in names
    assert "apply_operations" in names
  end
end
