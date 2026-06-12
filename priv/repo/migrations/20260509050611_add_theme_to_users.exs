defmodule DoIt.Repo.Migrations.AddThemeToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :theme, :string, size: 16
    end
  end
end
