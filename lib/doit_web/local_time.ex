defmodule DoItWeb.LocalTime do
  @moduledoc """
  Converts a stored UTC timestamp to the deployment's local time for display.
  Storage stays UTC (DateTime.utc_now/0) — only rendering should call this.
  Uses the BEAM's OS-aware local-time conversion (:calendar), so it follows
  whatever TZ the container/host is configured with — no hardcoded zone name,
  no extra timezone-database dependency.
  """
  def from_utc(%DateTime{} = utc) do
    {date, time} =
      utc
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()
      |> :calendar.universal_time_to_local_time()

    NaiveDateTime.from_erl!({date, time}, utc.microsecond)
  end
end
