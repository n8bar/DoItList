defmodule DoIt.Repo.Migrations.AddAiKnobsToInitiatives do
  use Ecto.Migration

  def change do
    alter table(:initiatives) do
      add :ai_knobs, :text
    end
  end
end
