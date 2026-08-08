defmodule DoitMcp.Client do
  @moduledoc """
  The only module that speaks HTTP. Every tool/resource calls through here —
  this is the boundary that keeps the adapter a thin translation layer over
  the public API (Arc 1, `/api/v1`), never a shortcut into the Elixir contexts.
  """

  alias DoitMcp.TokenRecovery

  @doc """
  POST an ordered batch of operations to `/api/v1/operations`.

  `opts[:idempotency_key]`, when a non-empty string, is sent as the
  `Idempotency-Key` request header so a retried batch is de-duplicated
  server-side (m03.03 worklist 2.2). Enforcement is entirely the API's; this
  just forwards the header.
  """
  @spec operations([map()], keyword()) :: {:ok, [map()]} | {:error, map()}
  def operations(ops, opts \\ []) when is_list(ops) do
    request(:post, "/api/v1/operations", [json: %{operations: ops}] ++ idempotency_header(opts))
  end

  defp idempotency_header(opts) do
    case Keyword.get(opts, :idempotency_key) do
      key when is_binary(key) and key != "" -> [headers: %{"idempotency-key" => key}]
      _ -> []
    end
  end

  @doc "GET a read endpoint under `/api/v1`."
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, map()}
  def get(path, params \\ []) do
    request(:get, path, params: params)
  end

  @doc """
  POST a JSON `body` to a path under `/api/v1` — e.g. the import-confirm
  park (m03.04 item 30.1).
  """
  @spec post(String.t(), map()) :: {:ok, term()} | {:error, map()}
  def post(path, body) when is_map(body) do
    request(:post, path, json: body)
  end

  defp request(method, path, opts) do
    attempt = fn token ->
      [
        base_url: base_url(),
        auth: {:bearer, token},
        method: method,
        url: path,
        # A tool call is a synchronous round trip for whoever is waiting on the
        # MCP response (an agent or a human at a prompt) — fail fast and let
        # the caller decide whether to retry, instead of Req's default silent
        # multi-second backoff-and-retry on a transient error.
        retry: false,
        # A cushion ABOVE the server's deliberate worst case (a cap-sized batch
        # is bounded by the 60s transaction timeout; m03.04 items 3.8.3 + 2.17),
        # not a mask for a slow server — the client must never give up while the
        # server is still legitimately working, so this stays above that bound.
        receive_timeout: 90_000
      ]
      |> Keyword.merge(Application.get_env(:doit_mcp, :req_options, []))
      |> Req.new()
      |> Req.merge(opts)
      |> Req.request()
    end

    dispatch(attempt)
  end

  # The credential is the session's in-memory override when a 401 recovery
  # installed one, else the bearer header this request arrived with
  # (installed per request task by DoitMcp.Server.handle_request/2) — never a
  # VM-wide token, which would hand one session another's identity (m03.04
  # item 23.2). A rejected or absent credential runs the per-session recovery
  # ladder (TokenRecovery.Http, m03.04 item 23.3) HERE, on the one path every
  # tool and resource shares: elicit over THAT session's own stream, retry
  # once with an accepted token, actionable guidance on every other outcome —
  # all of it in the standard error envelope, so ToolResult/ResourceResult
  # render it with zero per-tool code.
  defp dispatch(attempt) do
    case TokenRecovery.Http.credential() do
      {:ok, token} ->
        case attempt.(token) do
          {:ok, %Req.Response{status: 401}} -> recover_unauthorized(attempt)
          other -> translate(other)
        end

      :absent ->
        # No credential at all — same ladder, minus the doomed round trip.
        recover_unauthorized(attempt)
    end
  end

  defp recover_unauthorized(attempt) do
    case TokenRecovery.Http.recover() do
      {:ok, fresh_token} ->
        # The accept→retry window, per session (m03.04 2.20 mirrored):
        # TokenRecovery.Http holds this session's verify-in-flight guard so
        # a concurrent 401 on the SAME session joins this recovery instead
        # of re-eliciting; the `after` clears it on every exit. Holder-only:
        # a joiner's pass through here leaves the verifier's guard alone.
        try do
          case attempt.(fresh_token) do
            {:ok, %Req.Response{status: 401}} ->
              unauthorized_error(TokenRecovery.Http.refreshed_token_rejected())

            other ->
              translate(other)
          end
        after
          TokenRecovery.Http.verify_concluded()
        end

      {:error, message} ->
        unauthorized_error(message)
    end
  end

  # Same envelope shape the API's own errors use, so the shared result
  # translators render the actionable message as the tool/resource error.
  defp unauthorized_error(message) do
    {:error,
     %{status: 401, body: %{"error" => %{"code" => "unauthorized", "message" => message}}}}
  end

  defp translate(result) do
    case result do
      {:ok, %Req.Response{status: status, body: %{"data" => data}}} when status in 200..299 ->
        {:ok, data}

      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, %{status: status, body: body}}

      {:error, exception} ->
        {:error, %{status: nil, reason: Exception.message(exception)}}
    end
  end

  # The base URL is the adapter's process env, set once by the compose service
  # that runs it — the one piece of API config that is the SERVICE's, not a
  # session's. The credential is never here: it rides each session's own
  # request (see dispatch/1).
  defp base_url, do: System.get_env("DOITLIST_API_URL", "http://localhost:4000")
end
