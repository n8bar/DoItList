defmodule DoIt.Repo.Migrations.CreateAgentAccessAcks do
  use Ecto.Migration

  # m03.04 item 2.12.4: the one-time agent-trust acknowledgement, persisted per
  # (admin user, Initiative) so the trust confirm never re-shows for that pair,
  # across sessions. The unique index doubles as the idempotency guard.
  def change do
    create table(:agent_access_acks) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :initiative_id, references(:initiatives, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:agent_access_acks, [:user_id, :initiative_id])
    create index(:agent_access_acks, [:initiative_id])
  end
end
