defmodule DoitMcp.Tools.ExpectedVersion do
  @moduledoc """
  The one `expected_version` parameter description, shared by every write tool
  whose target carries a `version` (m03.04 3.4.3). One concept, one wording —
  and one place to edit when it changes.
  """

  @description "Always pass the `version` from your latest read; omit only for an unconditional overwrite. A stale value applies nothing and returns the current record; reconcile from it before retrying"

  @doc "The shared parameter description."
  def description, do: @description

  @doc """
  Puts a supplied `expected_version` into an op's `data`. An omitted (or nil)
  one leaves `data` untouched — exactly the unconditional write.
  """
  def put(data, params) do
    case Map.get(params, :expected_version) do
      nil -> data
      version -> Map.put(data, "expected_version", version)
    end
  end
end
