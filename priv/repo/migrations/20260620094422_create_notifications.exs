defmodule DoIt.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    # Per-user, cross-Initiative unread feed (m02.08 worklist 2). `kind` names
    # the event (member_added, assigned, co_assigned, …); `data` carries the
    # subject ids the flyout links to; `read_at` nil = unread. Schema/table only
    # here — generation + flyout land with a later agent.
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :data, :map, null: false, default: %{}
      add :read_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:notifications, [:user_id])
    # Newest-first per user with unread (read_at IS NULL) cheaply countable.
    create index(:notifications, [:user_id, :read_at])
  end
end
