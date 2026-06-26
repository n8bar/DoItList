defmodule DoIt.Accounts.ApiTokensTest do
  @moduledoc """
  API token context (m03.01 worklist 1.1): mint returns the plaintext exactly
  once and stores only a hash; revoke stops resolution; resolving touches
  `last_used_at`; garbage/revoked tokens don't resolve.
  """
  use DoIt.DataCase, async: true

  alias DoIt.Accounts
  alias DoIt.Accounts.ApiToken

  defp user(name \\ "tok") do
    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{System.unique_integer([:positive])}@example.com",
        "username" => "#{name}-#{System.unique_integer([:positive])}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  describe "mint_api_token/2" do
    test "returns the plaintext once and stores only its hash" do
      user = user()
      {:ok, {plaintext, token}} = Accounts.mint_api_token(user, "laptop")

      assert is_binary(plaintext)
      assert String.starts_with?(plaintext, "doit_pat_")
      assert token.label == "laptop"
      assert token.user_id == user.id

      # The persisted row never holds the plaintext.
      stored = Repo.get!(ApiToken, token.id)
      refute stored.token_hash == plaintext
      assert stored.token_hash == :crypto.hash(:sha256, plaintext) |> Base.encode16(case: :lower)

      # The plaintext is nowhere in the DB column.
      assert Repo.aggregate(
               from(t in ApiToken, where: t.token_hash == ^plaintext),
               :count
             ) == 0
    end

    test "blank label is normalized to nil" do
      {:ok, {_pt, token}} = Accounts.mint_api_token(user(), "   ")
      assert token.label == nil
    end

    test "an over-long label is rejected" do
      assert {:error, changeset} = Accounts.mint_api_token(user(), String.duplicate("x", 101))
      assert %{label: [_ | _]} = errors_on(changeset)
    end

    test "two mints produce distinct tokens" do
      user = user()
      {:ok, {pt1, _}} = Accounts.mint_api_token(user, "a")
      {:ok, {pt2, _}} = Accounts.mint_api_token(user, "b")
      refute pt1 == pt2
    end

    test "minting is capped per user; revoking frees a slot" do
      user = user()
      max = Accounts.max_active_api_tokens()

      tokens =
        for n <- 1..max do
          {:ok, {_pt, token}} = Accounts.mint_api_token(user, "t#{n}")
          token
        end

      # At the cap, the next mint is refused (no new row written).
      assert {:error, :token_limit_reached} = Accounts.mint_api_token(user, "over")
      assert length(Accounts.list_api_tokens(user)) == max

      # Revoking one frees a slot so a mint succeeds again.
      {:ok, _} = Accounts.revoke_api_token(user, hd(tokens).id)
      assert {:ok, {_pt, _token}} = Accounts.mint_api_token(user, "after-revoke")
    end
  end

  describe "fetch_user_by_api_token/1" do
    test "resolves a valid token to its user and touches last_used_at" do
      user = user()
      {:ok, {plaintext, token}} = Accounts.mint_api_token(user, "cli")

      assert Repo.get!(ApiToken, token.id).last_used_at == nil

      resolved = Accounts.fetch_user_by_api_token(plaintext)
      assert resolved.id == user.id

      assert %DateTime{} = Repo.get!(ApiToken, token.id).last_used_at
    end

    test "garbage / unknown token resolves to nil" do
      assert Accounts.fetch_user_by_api_token("doit_pat_not_a_real_token") == nil
      assert Accounts.fetch_user_by_api_token("") == nil
      assert Accounts.fetch_user_by_api_token(nil) == nil
    end

    test "a revoked token no longer resolves" do
      user = user()
      {:ok, {plaintext, token}} = Accounts.mint_api_token(user, "temp")
      assert Accounts.fetch_user_by_api_token(plaintext).id == user.id

      {:ok, _} = Accounts.revoke_api_token(user, token.id)
      assert Accounts.fetch_user_by_api_token(plaintext) == nil
    end
  end

  describe "list_api_tokens/1 and revoke_api_token/2" do
    test "lists a user's tokens, newest first" do
      user = user()
      {:ok, {_, _t1}} = Accounts.mint_api_token(user, "one")
      {:ok, {_, t2}} = Accounts.mint_api_token(user, "two")

      tokens = Accounts.list_api_tokens(user)
      assert length(tokens) == 2
      assert hd(tokens).id == t2.id
    end

    test "revoke is scoped to the owner" do
      owner = user("owner")
      other = user("other")
      {:ok, {_, token}} = Accounts.mint_api_token(owner, "mine")

      # Another user can't revoke it.
      assert {:error, :not_found} = Accounts.revoke_api_token(other, token.id)
      assert Repo.get(ApiToken, token.id)

      # The owner can.
      assert {:ok, _} = Accounts.revoke_api_token(owner, token.id)
      assert Repo.get(ApiToken, token.id) == nil
    end
  end
end
