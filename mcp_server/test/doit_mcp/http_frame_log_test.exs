defmodule DoitMcp.HttpFrameLogTest do
  # async: false — boots the anubis HTTP tree under its real global registry
  # names and swaps global app env (:transport_mode, :req_options, and the
  # frame log's root and switch).
  use ExUnit.Case, async: false

  import Plug.Test, only: [conn: 3]

  alias DoitMcp.FrameLog

  @moduletag :capture_log

  # Per-session frame capture on the resident HTTP transport (m03.04 item
  # 23.5) — the server-side stand-in for the stdio launcher's host-side tee.
  # Every frame a session exchanges lands in that session's own JSONL file,
  # direction-tagged; no credential material lands anywhere in the log root.

  # The pasted replacement the API stub accepts, and a bearer value smuggled
  # inside a frame — neither may appear raw in any log file.
  @pasted_token "pasted-secret-token"
  @frame_bearer "leaked-secret-bearer"

  # What a spec-compliant client accepts, which is what makes the stock plug
  # answer a POST with an SSE stream rather than a JSON body.
  @stream_accept [{"accept", "application/json, text/event-stream"}]

  setup context do
    Application.put_env(:doit_mcp, :transport_mode, :http)
    previous_req = Application.fetch_env(:doit_mcp, :req_options)

    # ExUnit only clears a tmp_dir on the NEXT run, and these roots are 0700
    # — clean up so a log root never litters the checkout.
    if tmp_dir = context[:tmp_dir], do: on_exit(fn -> File.rm_rf!(tmp_dir) end)

    on_exit(fn ->
      Application.delete_env(:doit_mcp, :transport_mode)
      Application.delete_env(:doit_mcp, :frame_log_root)
      Application.delete_env(:doit_mcp, :frame_logs)

      case previous_req do
        {:ok, value} -> Application.put_env(:doit_mcp, :req_options, value)
        :error -> Application.delete_env(:doit_mcp, :req_options)
      end
    end)

    start_supervised!({DoitMcp.Server, transport: {:streamable_http, start: true}})
    :ok
  end

  # Capture writes are casts — flush the logger's mailbox before reading.
  defp sync, do: _ = :sys.get_state(FrameLog)

  defp start_frame_log(root, enabled? \\ true) do
    Application.put_env(:doit_mcp, :frame_log_root, root)
    Application.put_env(:doit_mcp, :frame_logs, enabled?)
    start_supervised!(FrameLog)
    root
  end

  defp stub_api(test_pid, good_token \\ nil) do
    Application.put_env(:doit_mcp, :req_options,
      plug: fn conn ->
        [header] = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:api_call, header})

        if good_token == nil or header == "Bearer #{good_token}" do
          Req.Test.json(conn, %{"data" => %{"id" => 7, "email" => "op@example.com"}})
        else
          conn
          |> Plug.Conn.put_status(401)
          |> Req.Test.json(%{"error" => %{"code" => "unauthorized", "message" => "invalid"}})
        end
      end
    )
  end

  defp plug_opts, do: DoitMcp.Http.Plug.init(server: DoitMcp.Server)

  defp post_frame(message, headers) do
    conn =
      conn(:post, "/", JSON.encode!(message))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    |> DoitMcp.Http.Plug.call(plug_opts())
  end

  defp initialize_message(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "frame-log-test", "version" => "1.0"},
        "capabilities" => %{"elicitation" => %{}}
      }
    }
  end

  defp initialized_message, do: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

  defp get_me_call(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => "get_me", "arguments" => %{}}
    }
  end

  defp handshake(headers) do
    conn = post_frame(initialize_message(1), headers)
    assert conn.status == 200
    [session_id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    conn = post_frame(initialized_message(), [{"mcp-session-id", session_id} | headers])
    assert conn.status == 202
    session_id
  end

  defp tool_result(conn) do
    assert conn.status == 200
    assert %{"result" => result} = JSON.decode!(conn.resp_body)
    assert [%{"type" => "text", "text" => text} | _] = result["content"]
    {result["isError"], text}
  end

  # The session's own file, as parsed JSONL.
  defp lines(root, session_id) do
    [path] = Path.wildcard(Path.join(root, "#{session_id}.*.jsonl"))
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  defp methods(lines, dir) do
    for line <- lines, line["dir"] == dir, method = line["frame"]["method"], do: method
  end

  @tag :tmp_dir
  test "each session's frames land in its own file, direction-tagged", %{tmp_dir: tmp_dir} do
    root = start_frame_log(Path.join(tmp_dir, "frames"))
    stub_api(self())

    alpha = [{"authorization", "Bearer token-alpha"}]
    beta = [{"authorization", "Bearer token-beta"}]
    session_a = handshake(alpha)
    session_b = handshake(beta)

    assert {false, _text} =
             tool_result(post_frame(get_me_call(2), [{"mcp-session-id", session_a} | alpha]))

    conn =
      post_frame(%{"jsonrpc" => "2.0", "id" => 3, "method" => "tools/list"}, [
        {"mcp-session-id", session_b} | beta
      ])

    assert conn.status == 200
    sync()

    # The whole exchange, in order — the session's own initialize included:
    # its id is only assigned in the answer, so it must not land in a
    # pre-session bucket.
    a_lines = lines(root, session_a)
    assert methods(a_lines, "in") == ["initialize", "notifications/initialized", "tools/call"]
    assert Enum.count(a_lines, &(&1["dir"] == "out")) >= 2
    assert Enum.all?(a_lines, &(&1["ts"] =~ ~r/\A\d{4}-\d{2}-\d{2}T/))

    # A response frame carries no method — match the tool answer by id.
    assert Enum.any?(a_lines, &(&1["dir"] == "out" and &1["frame"]["id"] == 2))

    # Neither session's frames leak into the other's file.
    b_lines = lines(root, session_b)
    assert methods(b_lines, "in") == ["initialize", "notifications/initialized", "tools/list"]
    refute "tools/list" in methods(a_lines, "in")
    refute "tools/call" in methods(b_lines, "in")

    # One file per session, no third bucket.
    assert length(Path.wildcard(Path.join(root, "*.jsonl"))) == 2
    assert Bitwise.band(File.stat!(root).mode, 0o777) == 0o700
  end

  @tag :tmp_dir
  test "an elicitation rides the session's stream into its file; tokens never do", %{
    tmp_dir: tmp_dir
  } do
    root = start_frame_log(Path.join(tmp_dir, "frames"))
    stub_api(self(), @pasted_token)

    req = listener()
    dead = [{"authorization", "Bearer dead-token"} | @stream_accept]
    session = http_handshake(req, dead)
    headers = [{"mcp-session-id", session} | dead]
    stream = open_stream(req, session)

    # A frame smuggling bearer values over the wire — as a field, and as a
    # plain value.
    Req.post!(req,
      url: "/",
      json: %{
        "jsonrpc" => "2.0",
        "id" => 98,
        "method" => "ping",
        "params" => %{
          "authorization" => "Bearer #{@frame_bearer}",
          "note" => "Bearer #{@frame_bearer}"
        }
      },
      headers: headers
    )

    call = Task.async(fn -> Req.post!(req, url: "/", json: get_me_call(2), headers: headers) end)

    # The 401 raises the paste-a-fresh-token form on this session's stream.
    frame = await_sse_frame(stream)
    assert frame["method"] == "elicitation/create"

    answer =
      Req.post!(req,
        url: "/",
        json: %{
          "jsonrpc" => "2.0",
          "id" => frame["id"],
          "result" => %{"action" => "accept", "content" => %{"token" => @pasted_token}}
        },
        headers: headers
      )

    assert answer.status == 202

    # The held call resolved on the retry with the pasted token.
    assert [%{"result" => %{"isError" => false}}] = sse_frames(Task.await(call, 15_000).body)
    sync()

    session_lines = lines(root, session)

    # The server-to-client request went out on the stream, and the tool
    # answer came back as an SSE-shaped POST response: both captured, though
    # the stock plug wrote both.
    assert Enum.any?(
             session_lines,
             &(&1["dir"] == "out" and &1["frame"]["method"] == "elicitation/create")
           )

    assert Enum.any?(session_lines, &(&1["dir"] == "out" and &1["frame"]["id"] == 2))

    # The answer arrived carrying a pasted token; the log holds the field,
    # redacted.
    assert answer_line =
             Enum.find(session_lines, &(&1["frame"]["result"]["content"]["token"] != nil))

    assert answer_line["dir"] == "in"
    assert answer_line["frame"]["result"]["content"]["token"] == "[redacted]"

    # Bearer values are redacted by field and by shape.
    assert ping = Enum.find(session_lines, &(&1["frame"]["method"] == "ping"))
    assert ping["frame"]["params"]["authorization"] == "Bearer [redacted]"
    assert ping["frame"]["params"]["note"] == "Bearer [redacted]"

    # Nothing secret survives anywhere under the log root.
    logged =
      root
      |> Path.join("*")
      |> Path.wildcard()
      |> Enum.map_join(" ", &File.read!/1)

    refute logged =~ @pasted_token
    refute logged =~ @frame_bearer
    refute logged =~ "dead-token"
  end

  @tag :tmp_dir
  test "the off switch writes nothing at all", %{tmp_dir: tmp_dir} do
    root = start_frame_log(Path.join(tmp_dir, "frames"), false)
    stub_api(self())

    auth = [{"authorization", "Bearer token-alpha"}]
    session = handshake(auth)

    assert {false, _text} =
             tool_result(post_frame(get_me_call(2), [{"mcp-session-id", session} | auth]))

    sync()
    assert File.ls(root) in [{:error, :enoent}, {:ok, []}]
  end

  @tag :tmp_dir
  test "an unwritable root warns once and keeps serving", %{tmp_dir: tmp_dir} do
    # A path that cannot become a directory: every write fails, for root and
    # non-root alike.
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "")
    root = start_frame_log(Path.join(blocker, "frames"))
    stub_api(self())
    auth = [{"authorization", "Bearer token-alpha"}]

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        session = handshake(auth)

        assert {false, _text} =
                 tool_result(post_frame(get_me_call(2), [{"mcp-session-id", session} | auth]))

        sync()
      end)

    assert length(String.split(log, "frame log write failed")) == 2
    refute File.exists?(root)
  end

  # --- HTTP rig -------------------------------------------------------------
  # The elicitation leg needs the real thing: the stock plug writes the
  # session's server-to-client stream as SSE chunks over a live connection,
  # so that proof runs against a listener, with a client that reads the
  # stream and answers the form.

  defp listener do
    bandit =
      start_supervised!(
        {Bandit,
         plug: {DoitMcp.Http.Plug, server: DoitMcp.Server},
         ip: :loopback,
         port: 0,
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)
    Req.new(base_url: "http://127.0.0.1:#{port}", retry: false)
  end

  defp http_handshake(req, headers) do
    resp = Req.post!(req, url: "/", json: initialize_message(1), headers: headers)
    assert resp.status == 200
    [session_id] = Req.Response.get_header(resp, "mcp-session-id")

    resp =
      Req.post!(req,
        url: "/",
        json: initialized_message(),
        headers: [{"mcp-session-id", session_id} | headers]
      )

    assert resp.status == 202
    session_id
  end

  # The standalone GET stream. The stock plug registers the session's SSE
  # handler before it answers, so a returned response means the session can
  # be reached.
  defp open_stream(req, session_id) do
    resp =
      Req.get!(req,
        url: "/",
        headers: [{"accept", "text/event-stream"}, {"mcp-session-id", session_id}],
        into: :self,
        receive_timeout: 15_000
      )

    assert resp.status == 200
    resp
  end

  defp await_sse_frame(stream) do
    receive do
      message ->
        case Req.parse_message(stream, message) do
          {:ok, parts} ->
            case Enum.flat_map(parts, fn
                   {:data, data} -> sse_frames(data)
                   _other -> []
                 end) do
              [frame | _rest] -> frame
              [] -> await_sse_frame(stream)
            end

          _other ->
            await_sse_frame(stream)
        end
    after
      15_000 -> flunk("no SSE frame arrived on the session stream")
    end
  end

  defp sse_frames(data) do
    for line <- String.split(data, "\n"),
        String.starts_with?(line, "data: "),
        payload = String.trim_leading(line, "data: "),
        payload != "",
        do: JSON.decode!(payload)
  end
end
