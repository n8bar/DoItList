defmodule DoIt.Repo.Migrations.AddArchivedAndHiddenToInitiativeMembers do
  use Ecto.Migration

  def change do
    # Per-user archive + hide (m02.08 worklist 4). Both are per-member flags on
    # the membership row — never global — moving an Initiative out of that
    # member's active list. `archived_at` → restorable Archived list;
    # `hidden_at` → a lighter "off my dashboard" hide. The Assigned-to-Me query
    # (worklist 1) filters tasks from archived/hidden Initiatives by default.
    # Actions + UI land with a later agent; these columns exist now because the
    # worklist-1 query reads them.
    alter table(:initiative_members) do
      add :archived_at, :utc_datetime
      add :hidden_at, :utc_datetime
    end
  end
end
