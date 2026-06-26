defmodule DoItWeb.Api.AuthPlug do
  @moduledoc """
  Bearer-token authentication for `/api/v1` (m03.01 worklist 1.3).

  Reads `Authorization: Bearer <token>`, resolves the token to a user via
  `DoIt.Accounts.resolve_api_token/1`, and assigns the acting user as
  `:current_user` — matching how the rest of the app authorizes (the role checks
  take a `%User{}`). The token id is assigned as `:api_token_id` so the
  rate-limit plug, which runs next, can key on the specific token.

  A successful resolve bumps the token's `last_used_at` (inside
  `resolve_api_token/1`). A missing, malformed, invalid, or revoked token halts
  with a 401 in the documented single-error JSON shape.
  """

  import Plug.Conn

  alias DoIt.Accounts
  alias DoItWeb.Api.Errors

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, user, token_id} <- Accounts.resolve_api_token(token) do
      conn
      |> assign(:current_user, user)
      |> assign(:api_token_id, token_id)
    else
      _ ->
        Errors.send_error(conn, 401, :unauthorized, "Missing or invalid bearer token.")
    end
  end

  # Parse exactly one `Authorization: Bearer <token>` header. Anything else —
  # absent, wrong scheme, empty token, duplicated header — is a malformed
  # credential and resolves to 401.
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        case String.trim(token) do
          "" -> :error
          token -> {:ok, token}
        end

      _ ->
        :error
    end
  end
end
