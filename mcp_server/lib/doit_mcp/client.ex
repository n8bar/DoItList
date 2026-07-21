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
        # A cushion over the server's fixed worst case (a cap-sized batch is
        # bounded by the 15s transaction timeout; m03.04 item 3.8.3), not a
        # mask for a slow server — Req's ~15s default sat exactly ON that
        # bound and turned drive 4's 14.6s batch into a spurious timeout.
        receive_timeout: 30_000
      ]
      |> Keyword.merge(Application.get_env(:doit_mcp, :req_options, []))
      |> Req.new()
      |> Req.merge(opts)
      |> Req.request()
    end

    case attempt.(TokenRecovery.token()) do
      # The token died out from under the session — the stdio handshake makes
      # no API call, so connect never caught it. Recovery lives HERE, on the
      # one path every tool and resource shares (m03.04 item 2.13): the first
      # 401 may elicit a fresh token and retry ONCE; every non-recovery
      # outcome comes back in the standard error envelope with an actionable
      # message, so ToolResult/ResourceResult render it with zero per-tool
      # code.
      {:ok, %Req.Response{status: 401}} -> recover_unauthorized(attempt)
      other -> translate(other)
    end
  end

  defp recover_unauthorized(attempt) do
    case TokenRecovery.recover() do
      {:ok, fresh_token} ->
        case attempt.(fresh_token) do
          # The pasted replacement is dead too — latch (no elicit loop) and
          # surface the manual fix instead of asking again.
          {:ok, %Req.Response{status: 401}} ->
            unauthorized_error(TokenRecovery.refreshed_token_rejected())

          other ->
            translate(other)
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

  # The base URL is the MCP client's process env — set once by whatever
  # launches this adapter (`claude mcp add`, a generic stdio config block, …).
  # The token goes through DoitMcp.TokenRecovery: same env at boot, but an
  # in-session refresh (401 recovery, m03.04 item 2.13) can swap it.
  defp base_url, do: System.get_env("DOITLIST_API_URL", "http://localhost:4000")
end
