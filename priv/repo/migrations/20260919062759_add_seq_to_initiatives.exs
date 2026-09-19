defmodule DoIt.Repo.Migrations.AddSeqToInitiatives do
  use Ecto.Migration

  # m04.03 item 1.1: the per-Initiative delivery sequence. Advanced inside the
  # same transaction as each durable mutation (DoIt.Delta), so a subscriber
  # can tell a consecutive delta from a gap.
  def change do
    alter table(:initiatives) do
      add :seq, :bigint, null: false, default: 0
    end
  end
end
