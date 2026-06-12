defmodule DoIt.Repo.Migrations.SetUsernameNotNull do
  use Ecto.Migration

  # Safe to tighten: the add_username migration backfilled every row, and
  # registration now requires a username on every new account.
  def up do
    # Belt and suspenders for rows created between the two migrations.
    execute "UPDATE users SET username = 'user-' || id WHERE username IS NULL"

    alter table(:users) do
      modify :username, :string, null: false
    end
  end

  def down do
    alter table(:users) do
      modify :username, :string, null: true
    end
  end
end
