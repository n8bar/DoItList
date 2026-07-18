defmodule DoitMcp.ImportGate.Counter do
  @moduledoc """
  Session-lifetime memory behind the import gate's cumulative trigger
  (m03.04 item 2.11.2): task-adds applied per Initiative, plus the
  Initiatives whose import the operator already confirmed this session.

  Sub-cap chunking is sanctioned, so no single batch tells the whole story —
  the gate reads the session total, not the batch count. One Agent per
  adapter process; stdio is one session per OS process, so session lifetime
  equals process lifetime and nothing needs expiry.

  Keys are the same `t:DoitMcp.ImportGate.target/0` refs the gate evaluates.
  Every function degrades gracefully — zero / false / no-op — when the Agent
  isn't running (unit tests exercise tools without it).
  """

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(
      fn -> %{counts: %{}, confirmed: MapSet.new()} end,
      name: Keyword.get(opts, :name, name())
    )
  end

  @doc """
  The registered name this module talks to. Overridable via the
  `:import_gate_counter` app env for tests.
  """
  def name do
    Application.get_env(:doit_mcp, :import_gate_counter, __MODULE__)
  end

  @doc "Task-adds recorded against this target so far this session."
  @spec cumulative(DoitMcp.ImportGate.target()) :: non_neg_integer()
  def cumulative(target) do
    case Process.whereis(name()) do
      nil -> 0
      pid -> Agent.get(pid, &Map.get(&1.counts, target, 0))
    end
  end

  @doc """
  Record an applied batch's per-target task-add counts
  (`DoitMcp.ImportGate.count_by_target/1`'s shape).
  """
  @spec record([{DoitMcp.ImportGate.target(), pos_integer()}]) :: :ok
  def record(counts) when is_list(counts) do
    case Process.whereis(name()) do
      nil ->
        :ok

      pid ->
        Agent.update(pid, fn state ->
          %{
            state
            | counts:
                Enum.reduce(counts, state.counts, fn {target, n}, acc ->
                  Map.update(acc, target, n, &(&1 + n))
                end)
          }
        end)
    end
  end

  @doc "Remember that the operator confirmed an import into this target."
  @spec mark_confirmed(DoitMcp.ImportGate.target()) :: :ok
  def mark_confirmed(target) do
    case Process.whereis(name()) do
      nil -> :ok
      pid -> Agent.update(pid, &%{&1 | confirmed: MapSet.put(&1.confirmed, target)})
    end
  end

  @doc "Whether the operator already confirmed an import into this target."
  @spec confirmed?(DoitMcp.ImportGate.target()) :: boolean()
  def confirmed?(target) do
    case Process.whereis(name()) do
      nil -> false
      pid -> Agent.get(pid, &MapSet.member?(&1.confirmed, target))
    end
  end
end
