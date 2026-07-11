defmodule DoIt.Broadcast do
  @moduledoc """
  Transaction-aware PubSub, shared by every context that broadcasts a durable
  change (`DoIt.Tasks`, `DoIt.Initiatives`, `DoIt.Notifications`).

  A broadcast fired **mid-transaction** reaches subscribers while the writes are
  still invisible to their connections — they reload the OLD state and stay
  stale forever. Worse, in a multi-op batch (`DoItWeb.Api.Operations`) a message
  sent before the outer commit can outlive a rollback: a side effect escaping an
  all-or-nothing batch.

  So while inside a transaction the message is queued in the process dictionary
  and only fired by `flush/1` once the **outermost** transaction's result is
  known: `{:ok, _}` fires the queue (post-commit), anything else drops it
  (rollback). Outside a transaction `broadcast/2` fires immediately.

  The queue is keyed per process, so it is naturally request/caller-scoped. The
  test SQL sandbox shares one connection, so a mid-transaction broadcast looks
  committed to the test process; this deferral is what keeps that from being the
  case against real Postgres.
  """

  alias DoIt.Repo

  @pending :doit_pending_broadcasts

  @doc """
  Broadcast `message` on `topic`. Inside a transaction the message is queued for
  `flush/1` (post-commit); outside one it fires immediately. Always returns `:ok`.
  """
  def broadcast(topic, message) do
    if Repo.in_transaction?() do
      Process.put(@pending, [{topic, message} | Process.get(@pending, [])])
    else
      Phoenix.PubSub.broadcast(DoIt.PubSub, topic, message)
    end

    :ok
  end

  @doc """
  Run `fun` (0-arity) after the outermost transaction commits, riding the same
  queue as broadcasts: fired in enqueue order by `flush/1` on `{:ok, _}`,
  dropped on rollback and by `discard/1` (a dry-run/preview). Outside a
  transaction `fun` runs immediately. For non-PubSub post-commit side effects
  that need exactly the broadcasts' all-or-nothing deferral — e.g. the roll-up
  debounce enqueue (`DoIt.Tasks`), which must never fire for state that didn't
  commit. Always returns `:ok`.
  """
  def after_commit(fun) when is_function(fun, 0) do
    if Repo.in_transaction?() do
      Process.put(@pending, [{:after_commit, fun} | Process.get(@pending, [])])
    else
      fun.()
    end

    :ok
  end

  @doc """
  Flush (fire) or drop the queued broadcasts given a transaction `result`.

    * still inside a transaction — a no-op (an outer mutator will flush);
    * `{:ok, _}` — fire the queued messages in enqueue order, then clear it;
    * anything else — drop the queue (a rolled-back batch broadcasts nothing).

  `coalesce` (optional) maps the enqueue-ordered entry list to the list
  actually fired, on the commit path only — so a multi-op batch can collapse
  its per-op messages into per-batch ones (`DoIt.Tasks.coalesce_task_broadcasts/1`)
  instead of fanning N identical reload signals at every subscriber. The
  entries are `{topic, message}` tuples plus `{:after_commit, fun}` markers; a
  coalescer must pass anything it doesn't understand through untouched. This
  module stays domain-agnostic — the message vocabulary lives with the caller.

  Returns `result` unchanged so it can sit in a pipe.
  """
  def flush(result, coalesce \\ &Function.identity/1) do
    cond do
      Repo.in_transaction?() ->
        result

      match?({:ok, _}, result) ->
        pending = Process.get(@pending, [])
        Process.delete(@pending)

        for entry <- pending |> Enum.reverse() |> coalesce.() do
          case entry do
            {:after_commit, fun} -> fun.()
            {topic, message} -> Phoenix.PubSub.broadcast(DoIt.PubSub, topic, message)
          end
        end

        result

      true ->
        Process.delete(@pending)
        result
    end
  end

  @doc "Drop any queued broadcasts unconditionally (a dry-run/preview). Returns `result`."
  def discard(result) do
    Process.delete(@pending)
    result
  end
end
