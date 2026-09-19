defmodule DoIt.Delta do
  @moduledoc """
  The canonical delta envelope (m04.03 worklist 1): one post-commit message
  per committed Initiative mutation, ordered by a per-Initiative sequence.

  ## Sequence (item 1.1)

  `initiatives.seq` advances **inside** the mutating transaction — the first
  `enqueue/2` (or note) for an Initiative in the current transaction runs one
  `UPDATE ... SET seq = seq + 1 RETURNING seq` and remembers the value in the
  process dictionary; later broadcasts in the same transaction reuse it. One
  transaction ⇒ one step ⇒ one envelope per Initiative, and a rollback never
  consumes a number (the row update rolls back with everything else), so a
  subscriber sees consecutive sequences or a real gap, never a phantom one.

  The operations batch defers its bumps to its last step
  (`with_deferred_seq/1` + `advance_deferred/0`) so the Initiative row lock is
  taken once, late, and briefly — a long import doesn't hold every other
  member's single edit behind it for the batch's duration.

  ## Envelope (item 1.2)

  Built once at flush time (post-commit, `flush/2`) from the queued entries of
  each `"initiative:<id>"` topic — the legacy `{kind, id}` tuples plus the
  `{:delta_note, kind, ids}` entries the contexts enqueue where a tuple names
  fewer records than actually changed (`note_changed/2`, `note_removed/2`) —
  and published as `{:initiative_delta, envelope}` on the same topic, after the
  tuples. Notes are stripped before the tuples fire; nothing else changes for
  the tuple subscribers (the LiveView workspace).

  Records are read once per envelope, post-commit: the Initiative's live tree
  (positions, depth, and index labels are tree-derived, so the serializer
  needs the whole tree once — the same read the snapshot does) and each
  changed id still in it is serialized in the snapshot's task-node shape. An
  id that is gone by read time is omitted; the transaction that removed it
  carries the removal in its own envelope.

  `origin_key` and `actor` come from `with_origin/2`, which the operations
  endpoint enters for the request; nothing else sets them, so they are `nil`
  on the paths no client write started (the roll-up pass, the LiveView).
  """

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Broadcast, Initiatives, Repo, Tasks}
  alias DoIt.Accounts.User
  alias DoIt.Initiatives.Initiative
  alias DoItWeb.Api.Serializer

  # %{initiative_id => seq} advanced in the current transaction.
  @seqs :doit_delta_seqs
  # Initiative ids awaiting the batch-end bump; absent = not deferring.
  @deferred :doit_delta_deferred
  # %{key: idempotency key | nil, actor: %User{} | nil} for the request.
  @origin :doit_delta_origin

  @changed_kinds [:task_created, :task_updated, :task_moved, :comment_added, :comment_changed]

  def topic(initiative_id), do: "initiative:#{initiative_id}"

  # --- Queueing ---------------------------------------------------------------

  @doc """
  Queue `message` on the Initiative's topic (through `DoIt.Broadcast`) and
  advance its sequence in the same transaction. Outside any transaction the
  bump and the message get a one-statement transaction of their own, flushed
  at once — so a stray non-transactional write still yields a sequenced
  envelope rather than a tuple with no delta behind it.
  """
  def enqueue(initiative_id, message) do
    if Repo.in_transaction?() do
      touch(initiative_id)
      Broadcast.broadcast(topic(initiative_id), message)
    else
      {:ok, :ok} = Repo.transaction(fn -> enqueue(initiative_id, message) end) |> flush()
      :ok
    end
  end

  @doc "Record that these task ids changed content or place, for the envelope's `upserts`."
  def note_changed(initiative_id, ids), do: note(initiative_id, :changed, ids)

  @doc "Record that these task ids left the live tree, for the envelope's `removed`."
  def note_removed(initiative_id, ids), do: note(initiative_id, :removed, ids)

  defp note(_initiative_id, _kind, []), do: :ok
  defp note(initiative_id, kind, ids), do: enqueue(initiative_id, {:delta_note, kind, ids})

  @doc """
  Make sure this Initiative's sequence has advanced in the current transaction
  (once; a repeat is free). Deferred to `advance_deferred/0` inside
  `with_deferred_seq/1`.
  """
  def touch(initiative_id) do
    cond do
      Map.has_key?(seqs(), initiative_id) -> :ok
      deferring?() -> Process.put(@deferred, MapSet.put(deferred(), initiative_id))
      true -> advance(initiative_id)
    end

    :ok
  end

  defp advance(initiative_id) do
    # Schemaless on purpose: the bump is one row update and this module must
    # not pull the Initiatives schema into every task write path.
    from(i in "initiatives", where: i.id == type(^initiative_id, :integer), select: i.seq)
    |> Repo.update_all(inc: [seq: 1])
    |> case do
      {1, [seq]} -> Process.put(@seqs, Map.put(seqs(), initiative_id, seq))
      # The Initiative is gone (purged mid-flight): nothing left to order.
      _ -> :ok
    end

    :ok
  end

  @doc "The sequences advanced so far in this process: `%{initiative_id => seq}`."
  def seqs, do: Process.get(@seqs, %{})

  @doc """
  Run `fun` with sequence bumps deferred: `touch/1` only remembers the
  Initiative, and `advance_deferred/0` — the batch's last statement — bumps
  each remembered one. Reentrant; torn down in `after`.
  """
  def with_deferred_seq(fun) do
    if deferring?() do
      fun.()
    else
      Process.put(@deferred, MapSet.new())

      try do
        fun.()
      after
        Process.delete(@deferred)
      end
    end
  end

  @doc "Bump every Initiative `touch/1` remembered under `with_deferred_seq/1`."
  def advance_deferred do
    Enum.each(deferred(), &advance/1)
    if deferring?(), do: Process.put(@deferred, MapSet.new())
    :ok
  end

  defp deferring?, do: Process.get(@deferred) != nil
  defp deferred, do: Process.get(@deferred) || MapSet.new()

  # --- Origin ------------------------------------------------------------------

  @doc """
  Run `fun` with the request's origin — `%{key: idempotency_key | nil, actor:
  %User{}}` — available to every envelope it flushes.
  """
  def with_origin(%{} = origin, fun) do
    previous = Process.put(@origin, origin)

    try do
      fun.()
    after
      if previous, do: Process.put(@origin, previous), else: Process.delete(@origin)
    end
  end

  defp origin, do: Process.get(@origin) || %{}

  # --- Flush -------------------------------------------------------------------

  @doc """
  `DoIt.Broadcast.flush/2` with the envelopes: on commit, every queued entry
  is fired through `coalesce` (notes stripped first) and then one
  `{:initiative_delta, envelope}` per touched Initiative. Clears the
  remembered sequences once the outermost transaction is done, whichever way.
  Returns `result` unchanged.
  """
  def flush(result, coalesce \\ &Function.identity/1) do
    result = Broadcast.flush(result, coalescer(coalesce))
    unless Repo.in_transaction?(), do: clear()
    result
  end

  @doc "Drop the queue and the remembered sequences (a dry run / a raised batch). Returns `result`."
  def discard(result) do
    Broadcast.discard(result)
    clear()
    result
  end

  defp clear do
    Process.delete(@seqs)
    if deferring?(), do: Process.put(@deferred, MapSet.new())
    :ok
  end

  defp coalescer(coalesce) do
    fn entries ->
      envelopes = envelopes(entries)
      legacy = entries |> Enum.reject(&note?/1) |> coalesce.()
      legacy ++ envelopes
    end
  end

  defp note?({_topic, {:delta_note, _kind, _ids}}), do: true
  defp note?(_entry), do: false

  # --- Envelope ----------------------------------------------------------------

  @doc """
  The `{topic, {:initiative_delta, envelope}}` entries for a flushed queue —
  one per Initiative whose sequence advanced. Public for tests; `flush/2`
  is the production caller.
  """
  def envelopes(entries) do
    seqs = seqs()

    entries
    |> Enum.group_by(&initiative_of/1, &elem(&1, 1))
    |> Enum.flat_map(fn
      {nil, _messages} ->
        []

      {initiative_id, messages} ->
        case Map.fetch(seqs, initiative_id) do
          {:ok, seq} -> envelope(initiative_id, seq, messages) |> List.wrap()
          :error -> []
        end
    end)
    |> Enum.map(fn env -> {topic(env.initiative_id), {:initiative_delta, env}} end)
  end

  defp initiative_of({"initiative:" <> id, _message}) do
    case Integer.parse(id) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp initiative_of(_entry), do: nil

  # nil when the Initiative row is gone — nobody left to converge.
  defp envelope(initiative_id, seq, messages) do
    case Repo.get(Initiative, initiative_id) do
      nil -> nil
      initiative -> build(initiative, seq, messages)
    end
  end

  defp build(initiative, seq, messages) do
    changed = collect(messages, :changed)
    removed = collect(messages, :removed)
    header? = Enum.any?(messages, &match?({:initiative_updated, _}, &1))

    {upserts, patch} =
      if changed == [] and not header?,
        do: {[], nil},
        else: read_records(initiative, changed)

    live = MapSet.new(upserts, & &1.id)

    %{
      initiative_id: initiative.id,
      seq: seq,
      origin_key: Map.get(origin(), :key),
      actor: actor(Map.get(origin(), :actor)),
      upserts: upserts,
      removed: Enum.reject(removed, &MapSet.member?(live, &1)),
      initiative: patch,
      members_changed: Enum.any?(messages, &match?({:members_changed, _}, &1))
    }
  end

  defp collect(messages, :changed) do
    messages
    |> Enum.flat_map(fn
      {kind, id} when kind in @changed_kinds -> [id]
      {:delta_note, :changed, ids} -> ids
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp collect(messages, :removed) do
    messages
    |> Enum.flat_map(fn
      {:task_deleted, id} -> [id]
      {:delta_note, :removed, ids} -> ids
      _ -> []
    end)
    |> Enum.uniq()
  end

  # The same reads `DoItWeb.Api.Reads.initiative_tree/3` makes for a snapshot,
  # once per envelope: index labels, positions and depth are tree-derived.
  defp read_records(%Initiative{id: id} = initiative, changed) do
    tree = Tasks.initiative_task_tree(id)
    co_ids = Tasks.co_assignee_ids_for_initiative(id)
    comment_counts = Tasks.comment_counts_for_initiative(id)
    links = Tasks.list_links_for_initiative(id)
    %{subtitle: subtitle, progress: progress} = Initiatives.header(initiative)

    {Serializer.task_records(initiative, tree, co_ids, comment_counts, links, changed),
     Serializer.initiative_patch(initiative, tree, subtitle, progress)}
  end

  defp actor(%User{id: id, name: name, username: username}),
    do: %{id: id, name: name, username: username}

  defp actor(_), do: nil
end
