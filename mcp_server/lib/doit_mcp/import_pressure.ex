defmodule DoitMcp.ImportPressure do
  @moduledoc """
  Recent task-creation pressure per Initiative, read from the DATABASE
  (m03.04 3.1 iteration 2): `GET /initiatives/:id/task_count?created_at=` —
  tasks created inside the trailing window. Time-qualifies the import
  classifier's cumulative trigger: a human-rhythm drip (a few tasks, minutes
  apart) never accumulates, an import gulp lands at full weight, and pressure
  survives adapter restarts and reconnects (the old in-process counter reset
  to zero on every fresh connect). The window is adapter policy — the API
  serves the dumb fact. Pressure decays; a recorded readback does not
  (`DoitMcp.ImportGate.Counter` still holds the session's records).
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
  def recent(target), do: snapshot(target).recent

  @typedoc """
  Everything the one `task_count` read serves per target (m03.04 2.8.10):
  the windowed creation count (`recent`) and its done subset (`recent_done`),
  the whole live tree size (`live` — nil when the response doesn't say, so
  first-import detection stays fail-open), the Initiative's name, and its
  standing first-import declaration (nil when undeclared).
  """
  @type snapshot :: %{
          recent: non_neg_integer(),
          recent_done: non_neg_integer(),
          live: non_neg_integer() | nil,
          name: String.t() | nil,
          declaration: map() | nil
        }

  @doc """
  The target's full pressure/interview facts in ONE windowed `task_count`
  read — the same read `recent/1` always made, now carrying the import
  interview's inputs too. An in-batch Initiative has no history and no tree:
  zeros, no HTTP. Unreadable shapes fall back field by field (fail-open).
  """
  @spec snapshot(DoitMcp.ImportGate.target()) :: snapshot()
  def snapshot({:in_batch, _lid}) do
    %{recent: 0, recent_done: 0, live: 0, name: nil, declaration: nil}
  end

  def snapshot({:existing, id}) do
    since =
      DateTime.utc_now()
      |> DateTime.add(-@window_minutes, :minute)
      |> DateTime.to_iso8601()

    body =
      case Client.get(
             "/api/v1/initiatives/#{id}/task_count?created_at=#{URI.encode_www_form(since)}"
           ) do
        {:ok, body} when is_map(body) -> body
        _ -> %{}
      end

    %{
      recent: int_or(body["count"], 0),
      recent_done: int_or(body["done_count"], 0),
      live: int_or(body["live_count"], nil),
      name: if(is_binary(body["initiative_name"]), do: body["initiative_name"]),
      declaration: if(is_map(body["import_declaration"]), do: body["import_declaration"])
    }
  end

  defp int_or(value, _default) when is_integer(value) and value >= 0, do: value
  defp int_or(_value, default), do: default
end
