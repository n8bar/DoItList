defmodule DoIt.Repo.Migrations.IndexSortServerSide do
  use Ecto.Migration

  # m02.04 §2.6 — the Initiatives-index sort moves from localStorage to the
  # account. Reverse is remembered per mode (matching the shipped client
  # behavior), so the single boolean becomes a map keyed by mode.
  def change do
    alter table(:user_preferences) do
      remove :index_sort_reverse, :boolean, null: false, default: false
      add :index_sort_reverse_by_mode, :map, null: false, default: %{}
    end

    alter table(:initiative_members) do
      # The member's manual drag order on the index; nil sorts last, stable.
      add :sort_order, :integer
    end
  end
end
