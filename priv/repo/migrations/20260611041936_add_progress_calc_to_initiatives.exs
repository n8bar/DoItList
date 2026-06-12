defmodule DoIt.Repo.Migrations.AddProgressCalcToInitiatives do
  use Ecto.Migration

  def change do
    alter table(:initiatives) do
      add :progress_calc, :string, null: false, default: "leaf_average"
    end
  end
end
