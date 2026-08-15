defmodule DoitMcp.LogRedactionTest do
  # async: false — asserts on a VM-global Logger primary filter and boots the
  # anubis HTTP tree under its real registry names.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Test, only: [conn: 3]

  alias DoitMcp.LogRedaction

  require Logger

  # Credentials never reach the container log (m03.04 2.5.7): the dep's
  # transport-error path logs whole requests — bearer header included — so a
  # failed call would write a live token in plaintext on a multi-user
  # service. The guarantee is a Logger primary filter, so no dep version and
  # no future error path can leak one past a call-site fix.

  # A session bearer and a pasted recovery token; neither may survive into a
  # log line in any shape.
  @token "live-secret-token-23-7"
  @pasted "pasted-secret-token-23-7"

  setup do
    previous_req = Application.fetch_env(:doit_mcp, :req_options)

    on_exit(fn ->
      case previous_req do
        {:ok, value} -> Application.put_env(:doit_mcp, :req_options, value)
        :error -> Application.delete_env(:doit_mcp, :req_options)
      end
    end)

    :ok
  end

  # The API stub answers whatever the tool asks; the request task runs
  # outside the test's $callers chain, so inject a plain plug fun.
  defp stub_api do
    Application.put_env(:doit_mcp, :req_options,
      plug: fn conn ->
        Req.Test.json(conn, %{"data" => %{"id" => 1, "email" => "op@example.com"}})
      end
    )
  end

  defp plug_opts(extra \\ []), do: DoitMcp.Http.Plug.init([server: DoitMcp.Server] ++ extra)

  defp post_frame(message, headers, opts \\ plug_opts()) do
    conn =
      conn(:post, "/", JSON.encode!(message))
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("accept", "application/json")

    headers
    |> Enum.reduce(conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    |> DoitMcp.Http.Plug.call(opts)
  end

  defp handshake(headers) do
    message = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "clientInfo" => %{"name" => "log-redaction-test", "version" => "1.0"},
        "capabilities" => %{}
      }
    }

    conn = post_frame(message, headers)
    assert conn.status == 200
    [session_id] = Plug.Conn.get_resp_header(conn, "mcp-session-id")

    conn =
      post_frame(
        %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
        [{"mcp-session-id", session_id} | headers]
      )

    assert conn.status == 202
    session_id
  end

  defp event(msg, meta), do: %{level: :error, msg: msg, meta: meta}

  defp filtered(msg, meta \\ %{}) do
    filtered = LogRedaction.filter(event(msg, meta), [])
    refute filtered in [:stop, :ignore], "the filter must never drop an event"
    filtered
  end

  # What a handler would print: the message rendered, plus metadata, which
  # the default formatter drops but a JSON-shipping one would not.
  defp rendered(%{msg: msg, meta: meta}) do
    inspect({msg, meta}, limit: :infinity, printable_limit: :infinity)
  end

  test "the adapter's boot installs the filter, on every transport" do
    ids = Keyword.keys(:logger.get_primary_config().filters)
    assert LogRedaction.filter_id() in ids
  end

  test "a failed session call never logs the request's bearer" do
    stub_api()
    start_supervised!({DoitMcp.Server, transport: {:streamable_http, start: true}})

    headers = [{"authorization", "Bearer #{@token}"}]
    session = handshake(headers)

    call = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/call",
      "params" => %{"name" => "get_me", "arguments" => %{}}
    }

    # A zero timeout makes the dep's session call fail deterministically —
    # the same `session_call_failed` path a busy or dead session takes. Its
    # exit reason carries the whole call, request context and all.
    log =
      capture_log(fn ->
        conn =
          post_frame(call, [{"mcp-session-id", session} | headers], plug_opts(request_timeout: 0))

        assert %{"error" => %{"message" => _}} = JSON.decode!(conn.resp_body)
      end)

    assert log =~ "session_call_failed"
    assert log =~ "Bearer [redacted]"
    refute log =~ @token
  end

  test "a bearer is redacted in metadata, in nested report data, and in formatted text" do
    filtered = filtered({:string, "call failed: {\"authorization\", \"Bearer #{@token}\"}"})
    assert {:string, text} = filtered.msg
    assert text == "call failed: {\"authorization\", \"Bearer [redacted]\"}"

    filtered = filtered({:string, "routine line"}, %{authorization: "Bearer #{@token}"})
    assert filtered.meta.authorization == "Bearer [redacted]"

    report = %{
      reason: {:timeout, [{:mcp_request, %{"params" => %{"note" => "Bearer #{@token}"}}}]},
      req_headers: [{"authorization", "Bearer #{@token}"}, {"accept", "application/json"}]
    }

    filtered = filtered({:report, report})
    assert {:report, %{req_headers: headers, reason: reason}} = filtered.msg
    assert {"authorization", "Bearer [redacted]"} in headers
    assert {"accept", "application/json"} in headers
    assert {:timeout, [{:mcp_request, %{"params" => %{"note" => "Bearer [redacted]"}}}]} = reason

    # Erlang's format-and-args shape, and an already-formatted charlist.
    filtered = filtered({~c"failed ~p", [[authorization: "Bearer #{@token}"]]})
    refute rendered(filtered) =~ @token

    filtered = filtered({:string, ~c"charlist carrying Bearer #{@token}"})
    refute rendered(filtered) =~ @token

    # A bare credential under an authorization key — no bearer prefix to match.
    filtered = filtered({:report, [{"Authorization", @token}]})
    refute rendered(filtered) =~ @token
  end

  test "the recovery form's token field is redacted wherever it lands" do
    answer = %{
      "id" => 7,
      "result" => %{"action" => "accept", "content" => %{"token" => @pasted}}
    }

    filtered = filtered({:report, %{message: answer}})
    refute rendered(filtered) =~ @pasted

    # The same answer after a dep has already inspected it into text.
    filtered = filtered({:string, "session_call_failed: #{inspect(answer)}"})
    refute rendered(filtered) =~ @pasted

    log =
      capture_log(fn ->
        Logger.error("elicit answer #{inspect(answer)}")
      end)

    assert log =~ "elicit answer"
    refute log =~ @pasted
  end

  test "a pathological term neither crashes the logger nor stalls it" do
    # Structural sharing makes this term 2^24 nodes to a naive walk while
    # costing almost nothing to build — the reason the walk is bounded.
    bomb = Enum.reduce(1..24, "Bearer #{@token}", fn _, acc -> %{left: acc, right: acc} end)

    {micros, log} =
      :timer.tc(fn ->
        capture_log(fn ->
          Logger.error("bomb landed", bomb: bomb)
        end)
      end)

    assert log =~ "bomb landed"
    assert micros < 2_000_000, "the bounded walk took #{micros}us"

    # The same trick in chardata, which is why a message tree is walked
    # rather than flattened: this one flattens to gigabytes.
    chardata = Enum.reduce(1..24, "Bearer #{@token}", fn _, acc -> [acc, acc] end)
    {micros, filtered} = :timer.tc(fn -> filtered({:string, chardata}) end)
    assert micros < 2_000_000, "the bounded walk took #{micros}us"
    refute rendered(filtered) =~ @token

    # A filter that raises is removed by the logger, taking the guarantee
    # with it — it must still be installed.
    assert LogRedaction.filter_id() in Keyword.keys(:logger.get_primary_config().filters)
  end

  test "an event with no credential in it passes through untouched" do
    event = event({:string, "tool call finished in 12ms"}, %{pid: self(), tokenizer: "plain"})
    assert LogRedaction.filter(event, []) == event

    log = capture_log(fn -> Logger.error("tool call finished in 12ms") end)
    assert log =~ "tool call finished in 12ms"
  end
end
