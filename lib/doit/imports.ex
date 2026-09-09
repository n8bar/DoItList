defmodule DoIt.Imports do
  @moduledoc """
  Import records — the "this document already went into this tree" ledger behind
  `POST /api/v1/imports` (m03.04 2.3.5).

  Text import has no client-supplied key to dedupe on, so the **source text
  itself** is the key: a SHA-256 of the exact bytes, paired with the resolved
  target. An apply stores its 200 body once every batch has committed; a repeat
  apply of the same text into the same target replays that body rather than
  importing the document twice.

  ## Scoping

  The target decides who a record replays for:

    * `"initiative"` / `"task"` — an existing target. The key is the target and
      the text; **any** user who passes the endpoint's `:edit` authorization
      replays it, because the duplicate they would create is duplicate content
      in someone else's tree.
    * `"new_initiative"` — the target is only a requested *name*, so the key
      also carries the acting user. Two people are free to each import the same
      document into their own new Initiative.

  Rows are kept indefinitely: unlike a retry window, "this document is already
  in this tree" doesn't expire.

  ## Stored previews (6.7)

  A `preview: true` request also stores what it previewed — source text,
  filename, target, and the target Initiative's `version` — as a
  `DoIt.Imports.Preview`, keyed by the **access token and the target
  Initiative** (nil for a new one). The caller applies it later by
  `preview_id` without resending the document. A newer preview for the same
  key replaces the older row; an apply deletes the row; unapplied rows expire
  after `preview_ttl_seconds/0` and are reaped when that token stores its next
  preview — no scheduler.

  Pure storage logic over `DoIt.Imports.Import` and `DoIt.Imports.Preview` —
  no HTTP, no controller deps.
  """

  import Ecto.Query, only: [dynamic: 2, from: 2]

  alias DoIt.Accounts.User
  alias DoIt.Imports.{Import, Preview}
  alias DoIt.Repo

  # Retunable default: how long an unapplied preview stays applicable.
  @preview_ttl_seconds 3600

  @doc "Seconds an unapplied preview stays applicable."
  def preview_ttl_seconds, do: @preview_ttl_seconds

  @doc """
  The idempotency key for a source document: the lowercase hex SHA-256 of the
  exact text, byte for byte. Any edit to the source is a different import.
  """
  @spec source_hash(binary()) :: String.t()
  def source_hash(text) when is_binary(text) do
    :sha256 |> :crypto.hash(text) |> Base.encode16(case: :lower)
  end

  @doc """
  The earliest record matching `target` and `source_hash` for `user`, or `nil`.

  `target` is the resolved `{:new_initiative, name} | {:initiative, id} |
  {:task, id}` tuple. Existing targets ignore `user` (see "Scoping" above); a
  new-Initiative target is scoped to the acting user.
  """
  @spec fetch(User.t(), tuple(), String.t()) :: Import.t() | nil
  def fetch(%User{} = user, target, source_hash) when is_binary(source_hash) do
    target
    |> match_query(user)
    |> where_hash(source_hash)
    |> Repo.one()
  end

  @doc """
  Record a committed import: its target, the source hash, the Initiative it
  landed in, and the exact 200 body to replay.

  `user` is set programmatically. Returns `{:ok, %Import{}}`, or the changeset
  error — including the unique-constraint error when a racing request stored the
  same (target, text) first.
  """
  @spec record(User.t(), tuple(), String.t(), integer(), map()) ::
          {:ok, Import.t()} | {:error, Ecto.Changeset.t()}
  def record(%User{} = user, target, source_hash, initiative_id, response) do
    {kind, target_id, target_name} = describe(target)

    %Import{user_id: user.id}
    |> Import.changeset(%{
      source_hash: source_hash,
      target_kind: kind,
      target_id: target_id,
      target_name: target_name,
      initiative_id: initiative_id,
      response: response
    })
    |> Repo.insert()
  end

  @doc """
  Flatten a resolved target into its stored `{kind, target_id, target_name}`.
  """
  @spec describe(tuple()) :: {String.t(), integer() | nil, String.t() | nil}
  def describe({:new_initiative, name}), do: {"new_initiative", nil, name}
  def describe({:initiative, id}), do: {"initiative", id, nil}
  def describe({:task, id}), do: {"task", id, nil}

  # --- Stored previews (6.7) --------------------------------------------------

  @doc """
  Store a preview for `api_token_id`, replacing any live or expired one for the
  same target Initiative (`initiative` nil for a new-Initiative target) and
  reaping that token's expired rows. Returns the stored `%Preview{}`; its `id`
  is the `preview_id` the caller applies with.
  """
  @spec put_preview(integer(), tuple(), DoIt.Initiatives.Initiative.t() | nil, map()) ::
          {:ok, Preview.t()} | {:error, Ecto.Changeset.t()}
  def put_preview(api_token_id, target, initiative, attrs) when is_map(attrs) do
    {kind, target_id, target_name} = describe(target)
    initiative_id = initiative && initiative.id
    now = now()

    same_key =
      if initiative_id,
        do: dynamic([p], p.initiative_id == ^initiative_id),
        else: dynamic([p], is_nil(p.initiative_id))

    # This token's expired rows, plus its live row for this key.
    stale_or_same =
      dynamic([p], p.api_token_id == ^api_token_id and (p.expires_at <= ^now or ^same_key))

    Repo.transaction(fn ->
      Repo.delete_all(from p in Preview, where: ^stale_or_same)

      %Preview{id: Preview.generate_id(), api_token_id: api_token_id}
      |> Preview.changeset(
        Map.merge(attrs, %{
          initiative_id: initiative_id,
          initiative_version: initiative && initiative.version,
          target_kind: kind,
          target_id: target_id,
          target_name: target_name,
          expires_at: DateTime.add(now, @preview_ttl_seconds, :second)
        })
      )
      |> Repo.insert()
      |> case do
        {:ok, preview} -> preview
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  The live (unexpired) preview `id` stored for `api_token_id`, or `nil` — an
  unknown id, an expired one, or another token's id all read the same.
  """
  @spec fetch_preview(String.t(), integer()) :: Preview.t() | nil
  def fetch_preview(id, api_token_id) when is_binary(id) do
    now = now()

    Repo.one(
      from p in Preview,
        where: p.id == ^id and p.api_token_id == ^api_token_id and p.expires_at > ^now
    )
  end

  @doc "Consume a preview: delete its row so the id can't be applied twice."
  @spec delete_preview(Preview.t()) :: :ok
  def delete_preview(%Preview{id: id}) do
    Repo.delete_all(from p in Preview, where: p.id == ^id)
    :ok
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp match_query({:new_initiative, name}, %User{id: user_id}) do
    from i in Import,
      where:
        i.target_kind == "new_initiative" and i.target_name == ^name and i.user_id == ^user_id
  end

  defp match_query({kind, id}, _user) when kind in [:initiative, :task] do
    kind = to_string(kind)
    from i in Import, where: i.target_kind == ^kind and i.target_id == ^id
  end

  defp where_hash(query, source_hash) do
    from i in query, where: i.source_hash == ^source_hash, order_by: [asc: i.id], limit: 1
  end
end
