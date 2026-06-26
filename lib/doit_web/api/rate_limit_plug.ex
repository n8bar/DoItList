defmodule DoItWeb.Api.RateLimitPlug do
  @moduledoc """
  Enforces the per-token rate limit in the `/api/v1` pipeline (m03.01 worklist
  1.5).

  Runs **after** `AuthPlug`, so it keys on `:api_token_id` (the specific token,
  not the user — a user with several tokens gets independent budgets). Over the
  limit halts with a `429` in the documented single-error JSON shape, plus a
  `Retry-After` header (and a matching message) telling the client how long to
  wait.
  """

  alias DoIt.Api.RateLimiter
  alias DoItWeb.Api.Errors

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:api_token_id] do
      nil ->
        # No token assigned means auth didn't run / didn't pass; nothing to key
        # on. Leave it to the auth layer rather than inventing a budget.
        conn

      token_id ->
        case RateLimiter.check_rate(token_id) do
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
  end
end
