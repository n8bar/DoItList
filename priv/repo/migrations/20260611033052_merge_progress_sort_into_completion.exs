defmodule DoIt.Repo.Migrations.MergeProgressSortIntoCompletion do
  use Ecto.Migration

  @moduledoc """
  The "Progress" sort mode merged into "Completion %" (one menu entry, the
  percentage as the engine). Stored computed_progress modes become completion;
  anything missed degrades to manual via the unknown-mode fallback.
  """

  def up do
    execute("UPDATE tasks SET sort_mode = 'completion' WHERE sort_mode = 'computed_progress'")
  end

  def down, do: :ok
end
