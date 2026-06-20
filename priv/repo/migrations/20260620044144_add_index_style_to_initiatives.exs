defmodule DoIt.Repo.Migrations.AddIndexStyleToInitiatives do
  use Ecto.Migration

  # m02.07 item 1.7.2: the positional task-index style is a property of the tree
  # (per-Initiative), not the account. "none" is the default (no index shown).
  def change do
    alter table(:initiatives) do
      add :index_style, :string, null: false, default: "none"
    end
  end
end
