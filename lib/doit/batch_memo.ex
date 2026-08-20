defmodule DoIt.BatchMemo do
  @moduledoc """
  Batch-scoped read memo (m03.04 2.7.5.2), in the `with_resort_batching`
  pattern: a process-dictionary scope `DoItWeb.Api.Operations.apply_batch/2`
  enters around its transaction. Inside the scope, `fetch/2` serves repeated
  reads of the same slow-changing record — the Initiative row, a member role,
  user preferences, a resolved sort chain — from memory instead of re-querying
  once per op. Outside a scope every `fetch/2` just runs its loader: single-op
  paths (the LiveView calling the contexts directly) hit the DB exactly as
  before.

  Correctness over savings: any write to a memoized entity type busts its
  key(s) (`bust/1` / `bust_tag/1`) so the next read reloads — a batch that
  updates an Initiative and then adds a task must see the update. Writers call
  bust unconditionally; outside a scope it is a no-op. A `nil` loader result is
  never stored, so a memoized miss can't shadow a row created later in the
  batch.

  Keys are tuples tagged by entity, owned by the module that loads them:

    * `{:initiative, id}` — `DoIt.Initiatives.get_initiative/1`
    * `{:initiative_progress_calc, id}` — `DoIt.Tasks` progress-calc mode
    * `{:member_role, initiative_id, user_id}` — `DoIt.Initiatives.get_role/2`
    * `{:user_prefs, user_id}` — `DoIt.Accounts.get_preferences_by_user_id/1`
    * `{:resolved_sort, task_id}` — `DoIt.Tasks.resolve_sort/1`
  """

  @key :doit_batch_memo

  @doc "Run `fun` inside a memo scope. Reentrant: an existing scope is reused."
  def with_scope(fun) do
    if Process.get(@key) do
      fun.()
    else
      Process.put(@key, %{})

      try do
        fun.()
      after
        Process.delete(@key)
      end
    end
  end

  @doc """
  The memoized value for `key`, running `loader` (and storing a non-nil result)
  on a miss. Outside a scope, always runs `loader` — the memo-off passthrough.
  """
  def fetch(key, loader) do
    case Process.get(@key) do
      nil ->
        loader.()

      %{^key => value} ->
        value

      _memo ->
        value = loader.()
        # Re-read the scope AFTER the loader: a loader may itself write
        # through (`put/2` — e.g. a sort resolution memoizing its whole
        # chain), and storing into the pre-loader snapshot would drop those.
        case Process.get(@key) do
          nil -> :ok
          memo -> unless is_nil(value), do: Process.put(@key, Map.put(memo, key, value))
        end

        value
    end
  end

  @doc "Store a non-nil `value` under `key` (write-through). No-op outside a scope."
  def put(_key, nil), do: :ok

  def put(key, value) do
    case Process.get(@key) do
      nil -> :ok
      memo -> Process.put(@key, Map.put(memo, key, value))
    end

    :ok
  end

  @doc "Drop `key` so the next fetch reloads. No-op outside a scope."
  def bust(key) do
    case Process.get(@key) do
      nil -> :ok
      memo -> Process.put(@key, Map.delete(memo, key))
    end

    :ok
  end

  @doc "Drop every key whose tag (the tuple's first element) is `tag`."
  def bust_tag(tag) do
    case Process.get(@key) do
      nil ->
        :ok

      memo ->
        Process.put(@key, for({k, v} <- memo, elem(k, 0) != tag, into: %{}, do: {k, v}))
        :ok
    end
  end
end
