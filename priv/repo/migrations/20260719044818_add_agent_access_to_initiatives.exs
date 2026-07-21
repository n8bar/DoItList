defmodule DoIt.Repo.Migrations.AddAgentAccessToInitiatives do
  use Ecto.Migration

  # m03.04 item 2.12.1: per-Initiative agent access, off by default. Existing
  # rows land off; API/MCP-created Initiatives set it true server-side at
  # creation. Off means the /api/v1 surface treats the Initiative as not-found.
  def change do
    alter table(:initiatives) do
      add :agent_access, :boolean, default: false, null: false
    end
  end
end
