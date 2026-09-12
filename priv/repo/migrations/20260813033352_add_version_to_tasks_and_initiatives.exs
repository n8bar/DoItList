defmodule DoIt.Repo.Migrations.AddVersionToTasksAndInitiatives do
  use Ecto.Migration

  # Conditional writes (m03.04 item 32): an integer revision counter, bumped on
  # every intent-bearing write (not on derived computed_progress recomputes), so
  # a caller can send `expected_version` and never overwrite newer intent.
  # A counter, not updated_at — second-precision timestamps collide.
  def change do
    alter table(:tasks) do
      add :version, :integer, null: false, default: 1
    end

    alter table(:initiatives) do
      add :version, :integer, null: false, default: 1
    end
  end
end
