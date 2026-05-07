defmodule DoIt.Tasks.ActivityEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Orchards.Orchard
  alias DoIt.Tasks.Task

  schema "activity_events" do
    field :kind, :string
    field :data, :map, default: %{}

    belongs_to :task, Task
    belongs_to :orchard, Orchard
    belongs_to :user, User

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:task_id, :orchard_id, :user_id, :kind, :data])
    |> validate_required([:task_id, :orchard_id, :kind])
    |> validate_length(:kind, min: 1, max: 60)
  end
end
