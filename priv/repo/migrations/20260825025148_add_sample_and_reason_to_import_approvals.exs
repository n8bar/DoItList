defmodule DoIt.Repo.Migrations.AddSampleAndReasonToImportApprovals do
  use Ecto.Migration

  # m03.04 2.11.2 (cowboy): the card shows WHAT is being imported instead of
  # classifying why we stopped it — a sample drawn from the batch deepest
  # branch, so a flattened import reads as a flat list at a glance. The tasks
  # do not exist yet (nothing was applied), so the sample rides the park
  # payload. `decision_reason` carries the operator words back to the agent.
  def change do
    alter table(:import_approvals) do
      add :sample, :map, default: nil
      add :decision_reason, :string, size: 500, default: nil
    end
  end
end
