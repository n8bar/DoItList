defmodule DoitMcp.ImportPressure do
  @moduledoc """
  Recent task-creation pressure per Initiative, read from the DATABASE
  (m03.04 3.1 iteration 2): `GET /initiatives/:id/task_count?created_at=` —
  tasks created inside the trailing window. Time-qualifies the import gate's
  cumulative trigger: a human-rhythm drip (a few tasks, minutes apart) never
  accumulates, an import gulp lands at full weight, and pressure survives
  adapter restarts and reconnects (the old in-process counter reset to zero
  on every fresh connect). The window is adapter policy — the API serves the
  dumb fact. Pressure decays; the operator's session confirm does not
  (`DoitMcp.ImportGate.Counter` still holds sanctions).
  """

  alias DoitMcp.Client

  # The trailing window that counts as "this import". Retunable.
  @window_minutes 30

  @doc "The trailing window, for messages."
  @spec window_minutes() :: pos_integer()
  def window_minutes, do: @window_minutes

  @doc """
  Tasks created in the target Initiative inside the window. An Initiative
  born in THIS batch has no history — zero. A failed read is zero too
  (fail-open, the batch gate precedent): the apply surfaces the real error.
  """
  @spec recent(DoitMcp.ImportGate.target()) :: non_neg_integer()
  def recent({:in_batch, _lid}), do: 0

  def recent({:existing, id}) do
    since =
      DateTime.utc_now()
      |> DateTime.add(-@window_minutes, :minute)
      |> DateTime.to_iso8601()

    case Client.get("/api/v1/initiatives/#{id}/task_count?created_at=#{URI.encode_www_form(since)}") do
      {:ok, %{"count" => count}} when is_integer(count) -> count
      _ -> 0
    end
  end
end
