defmodule DoIt.Accounts.ApiTokens do
  @moduledoc """
  Mint, list, revoke, and resolve per-user API tokens (m03.01 worklist 1.1).

  ## The mint-once contract

  `mint_api_token/2` generates a strong random token, persists only its SHA-256
  hash, and returns `{plaintext, %ApiToken{}}`. The plaintext is available
  **only** from that one return value — it is never stored and cannot be
  recovered. Every later lookup hashes the *presented* token and matches it
  against the stored hash, so losing the plaintext means minting a new token.

  ## Hashing

  Tokens are 32 bytes of `:crypto.strong_rand_bytes/1`, URL-safe Base64 encoded
  (no padding), with a `doit_pat_` prefix so the secret is recognizable in logs
  and secret-scanners. The stored hash is `sha256(plaintext)`, hex-encoded.
  SHA-256 (not bcrypt) is the right tool here: the token is high-entropy random,
  so there is nothing to brute-force, and resolving a Bearer token must be fast
  and constant work per request.

  `user_id` and `token_hash` are set programmatically when building the struct —
  they are never cast from user input.
  """

  import Ecto.Query, warn: false

  alias DoIt.Repo
  alias DoIt.Accounts.{ApiToken, User}

  @token_bytes 32
  @token_prefix "doit_pat_"
  @max_active_tokens 25

  @doc """
  The per-user cap on simultaneously active (un-revoked) tokens.

  A ceiling, not a budget: per-token rate limits give each token its own
  budget, so without a cap a user could mint unlimited tokens to multiply their
  effective throughput. Bounding the token count bounds that aggregate.
  """
  def max_active_api_tokens, do: @max_active_tokens

  @doc """
  Mint a new token for `user` with an optional `label`.

  Returns `{:ok, {plaintext, %ApiToken{}}}` — the only time the plaintext is
  available — `{:error, changeset}` if the label is invalid, or
  `{:error, :token_limit_reached}` once the user is at `max_active_api_tokens/0`
  (revoke one to mint another).
  """
  def mint_api_token(%User{} = user, label \\ nil) do
    if count_active_tokens(user) >= @max_active_tokens do
      {:error, :token_limit_reached}
    else
      plaintext = generate_token()

      changeset =
        %ApiToken{user_id: user.id, token_hash: hash_token(plaintext)}
        |> ApiToken.changeset(%{"label" => label})

      case Repo.insert(changeset) do
        {:ok, token} -> {:ok, {plaintext, token}}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  defp count_active_tokens(%User{} = user) do
    Repo.aggregate(from(t in ApiToken, where: t.user_id == ^user.id), :count)
  end

  @doc "List a user's tokens, newest first. Hashes are redacted in the struct."
  def list_api_tokens(%User{} = user) do
    Repo.all(
      from t in ApiToken,
        where: t.user_id == ^user.id,
        order_by: [desc: t.inserted_at, desc: t.id]
    )
  end

  @doc """
  Revoke (delete) one of `user`'s tokens by id. Scoped to the user so a token
  can only be revoked by its owner. Returns `{:ok, token}` or `{:error, :not_found}`.
  """
  def revoke_api_token(%User{} = user, id) do
    case Repo.get_by(ApiToken, id: id, user_id: user.id) do
      nil -> {:error, :not_found}
      token -> Repo.delete(token)
    end
  end

  @doc """
  Resolve a presented plaintext token to the acting `%User{}`, or `nil`.

  Hashes the presented token and looks it up by `token_hash`. On a hit, bumps
  `last_used_at` and returns the user; otherwise returns `nil`. This is the
  named contract the auth plug ultimately rides on.
  """
  def fetch_user_by_api_token(plaintext) when is_binary(plaintext) do
    case resolve_api_token(plaintext) do
      {:ok, user, _token_id} -> user
      :error -> nil
    end
  end

  def fetch_user_by_api_token(_), do: nil

  @doc """
  Like `fetch_user_by_api_token/1` but also returns the token id, so callers
  (the rate limiter) can key on the specific token. Bumps `last_used_at` on a
  hit. Returns `{:ok, %User{}, token_id}` or `:error`.
  """
  def resolve_api_token(plaintext) when is_binary(plaintext) do
    hash = hash_token(plaintext)

    query =
      from t in ApiToken,
        where: t.token_hash == ^hash,
        join: u in assoc(t, :user),
        preload: [user: u]

    case Repo.one(query) do
      nil ->
        :error

      %ApiToken{user: %User{} = user} = token ->
        touch_last_used(token)
        {:ok, user, token.id}
    end
  end

  def resolve_api_token(_), do: :error

  @doc false
  # Exposed for the auth plug so the stored hash form stays in one place.
  def hash_token(plaintext) when is_binary(plaintext) do
    :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)
  end

  defp generate_token do
    @token_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(@token_bytes), padding: false)
  end

  defp touch_last_used(%ApiToken{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {_count, _} =
      from(t in ApiToken, where: t.id == ^id)
      |> Repo.update_all(set: [last_used_at: now])

    :ok
  end
end
