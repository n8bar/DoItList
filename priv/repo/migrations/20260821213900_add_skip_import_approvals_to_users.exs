defmodule DoIt.Repo.Migrations.AddSkipImportApprovalsToUsers do
  use Ecto.Migration

  # The account-level off-switch for the import-approval ceremony (m03.04
  # 2.8.9). Default false = the ceremony stays on for everyone; the operator
  # opts out on the account page only.
  def change do
    alter table(:users) do
      add :skip_import_approvals, :boolean, default: false, null: false
    end
  end
end
