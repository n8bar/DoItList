defmodule DoIt.Repo.Migrations.AddUsernameToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :username, :string
    end

    flush()

    # Backfill from the email local part, sanitized to the username charset
    # (lowercase letters, digits, _ and -), clipped to 20 so a collision
    # suffix still fits the 30-char app limit.
    execute """
    UPDATE users SET username =
      CASE
        WHEN length(regexp_replace(lower(split_part(email, '@', 1)), '[^a-z0-9_-]', '-', 'g')) >= 3
          THEN left(regexp_replace(lower(split_part(email, '@', 1)), '[^a-z0-9_-]', '-', 'g'), 20)
        ELSE 'user-' || id
      END
    """

    # De-dupe collisions deterministically: later ids get an id suffix.
    execute """
    UPDATE users u SET username = u.username || '-' || u.id
    WHERE EXISTS (SELECT 1 FROM users o WHERE o.username = u.username AND o.id < u.id)
    """

    create unique_index(:users, [:username])
  end

  def down do
    drop index(:users, [:username])

    alter table(:users) do
      remove :username
    end
  end
end
