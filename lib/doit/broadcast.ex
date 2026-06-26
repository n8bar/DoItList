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
  Flush (fire) or drop the queued broadcasts given a transaction `result`.

    * still inside a transaction — a no-op (an outer mutator will flush);
    * `{:ok, _}` — fire the queued messages in enqueue order, then clear it;
    * anything else — drop the queue (a rolled-back batch broadcasts nothing).

  Returns `result` unchanged so it can sit in a pipe.
  """
  def flush(result) do
    cond do
      Repo.in_transaction?() ->
        result

      match?({:ok, _}, result) ->
        pending = Process.get(@pending, [])
        Process.delete(@pending)

        for {topic, message} <- Enum.reverse(pending) do
          Phoenix.PubSub.broadcast(DoIt.PubSub, topic, message)
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
