defmodule DoItWeb.Api.IpRateLimitPlug do
  @moduledoc """
  Pre-auth per-IP throttle for `/api/v1` (m03.01 worklist 1.5).

  Runs **before** `AuthPlug`, so it caps every request — including
  unauthenticated ones — by source IP before the auth layer spends a SHA-256
  hash plus a DB round-trip resolving a presented Bearer token
  (`DoIt.Accounts.resolve_api_token/1`). Without this, an unauthenticated client
  could flood the endpoint with garbage tokens and the per-token limiter — which
  only meters traffic once a token is resolved — would never see them.

  This is a coarse connection-level safety net (a generous `ip_limit`, higher
  than the per-token `limit`), not a substitute for upstream/edge throttling. It
  keys on `conn.remote_ip`; behind a proxy that should be the real client IP
  (configure a trusted-proxy / forwarded-header step upstream).

  Over the limit halts with a `429` in the documented single-error JSON shape
  plus a `Retry-After` header, the same shape `RateLimitPlug` uses.
  """

  alias DoIt.Api.RateLimiter
  alias DoItWeb.Api.Errors

  @default_ip_limit 600

  def init(opts), do: opts

  def call(conn, opts) do
    limit = Keyword.get(opts, :limit, ip_limit())

    case RateLimiter.check_rate({:ip, conn.remote_ip}, limit: limit) do
      :ok ->
        conn

      {:error, retry_after} ->
        Errors.send_error(
          conn,
          429,
          :rate_limited,
          "Rate limit exceeded. Retry in #{retry_after}s.",
          headers: [{"retry-after", Integer.to_string(retry_after)}]
        )
    end
  end

  defp ip_limit do
    :doit
    |> Application.get_env(RateLimiter, [])
    |> Keyword.get(:ip_limit, @default_ip_limit)
  end
end
