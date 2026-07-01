defmodule DoItWeb.LocalTimeUsageTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards against a raw Calendar.strftime call bypassing DoItWeb.LocalTime's
  OS-local conversion (m03.01 timezone fix, 2026-06-30) — the only sanctioned
  Calendar.strftime call in lib/doit_web is inside the <.local_time/> component
  (core_components.ex). Everything else must render through that component.
  """

  test "Calendar.strftime is only called from the local_time component" do
    offenders =
      ["lib/doit_web/**/*.ex", "lib/doit_web/**/*.heex"]
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.reject(&(Path.basename(&1) == "core_components.ex"))
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} -> line =~ "Calendar.strftime(" end)
        |> Enum.map(fn {_line, n} -> "#{path}:#{n}" end)
      end)

    assert offenders == [],
           "Found a raw Calendar.strftime/2 call outside <.local_time/> " <>
             "(core_components.ex) — wrap the value in <.local_time value={..} " <>
             "format={..}/> so the display honors the OS's local time instead " <>
             "of raw UTC: #{inspect(offenders)}"
  end
end
