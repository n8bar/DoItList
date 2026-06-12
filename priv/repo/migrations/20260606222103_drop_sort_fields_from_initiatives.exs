defmodule DoIt.Repo.Migrations.DropSortFieldsFromInitiatives do
  use Ecto.Migration

  # Sort preference now lives entirely on tasks (the Initiative's root task is
  # where `resolve_sort` terminates). The Initiative-level columns are unused.
  def change do
    alter table(:initiatives) do
      remove :sort_mode, :string
      remove :sort_reverse, :boolean, default: false
    end
  end
end
