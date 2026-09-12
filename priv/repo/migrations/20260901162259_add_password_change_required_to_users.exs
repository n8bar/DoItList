defmodule DoIt.Repo.Migrations.AddPasswordChangeRequiredToUsers do
  use Ecto.Migration

  # Set programmatically only (e.g. after an admin-issued temp password) —
  # never cast from user params. Default false = no behavior change for
  # existing accounts.
  def change do
    alter table(:users) do
      add :password_change_required, :boolean, default: false, null: false
    end
  end
end
