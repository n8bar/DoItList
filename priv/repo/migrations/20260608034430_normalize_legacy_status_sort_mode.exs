defmodule DoIt.Repo.Migrations.NormalizeLegacyStatusSortMode do
  use Ecto.Migration

  # "status" was an earlier name for the completion-ordering mode (both rank by
  # task status). The mode was later renamed to "completion"; any rows still
  # holding the old value fail the sort engine. Map them forward.
  def up do
    execute("UPDATE tasks SET sort_mode = 'completion' WHERE sort_mode = 'status'")
  end

  def down do
    # Irreversible: migrated rows are indistinguishable from genuine "completion".
    :ok
  end
end
