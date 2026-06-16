defmodule DoIt.Tasks.ActivityEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.Initiative
  alias DoIt.Tasks.Task

  schema "activity_events" do
    field :kind, :string
    field :data, :map, default: %{}
    # Reversal data for the undo engine (m02.06): extras beyond the from/to in
    # `data` that an inverse needs — e.g. a move's prior sort position.
    field :inverse_payload, :map
    # When this event was undone (m02.06 item 3); nil = still applied. Drives
    # the per-(user, Initiative) undo / redo stack.
    field :undone_at, :utc_datetime

    belongs_to :task, Task
    belongs_to :initiative, Initiative
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:task_id, :initiative_id, :user_id, :kind, :data, :inverse_payload, :undone_at])
    |> validate_required([:task_id, :initiative_id, :kind])
    |> validate_length(:kind, min: 1, max: 60)
  end
end
