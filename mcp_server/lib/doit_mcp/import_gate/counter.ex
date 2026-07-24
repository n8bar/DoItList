defmodule DoitMcp.ImportGate.Counter do
  @moduledoc """
  Session-lifetime memory for the confirms the operator granted — import
  targets, and the progress-calc gate's key (`{:progress_calc, id,
  requested}`, fix 17). Pressure decays, sanction persists (m03.04 3.1
  iteration 2): task-creation PRESSURE now comes from the database's
  `inserted_at` window (`DoitMcp.ImportPressure`), so this Agent holds only
  what the operator said yes to. One Agent per adapter process; stdio is one
  session per OS process, so session lifetime equals process lifetime.

  Keys are the same `t:DoitMcp.ImportGate.target/0` refs the gate evaluates.
  Every function degrades gracefully — false / no-op — when the Agent isn't
  running (unit tests exercise tools without it).
  """

  use Agent

  def start_link(opts \\ []) do
    Agent.start_link(
      fn -> %{confirmed: MapSet.new()} end,
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

  @doc """
  Remember a confirm the operator granted this session — an import target,
  or one of the other gates' keys.
  """
  @spec mark_confirmed(term()) :: :ok
  def mark_confirmed(target) do
    case Process.whereis(name()) do
      nil -> :ok
      pid -> Agent.update(pid, &%{&1 | confirmed: MapSet.put(&1.confirmed, target)})
    end
  end

  @doc "Whether the operator already granted this confirm this session."
  @spec confirmed?(term()) :: boolean()
  def confirmed?(target) do
    case Process.whereis(name()) do
      nil -> false
      pid -> Agent.get(pid, &MapSet.member?(&1.confirmed, target))
    end
  end
end
