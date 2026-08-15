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

    # Execution provenance (m03.04 2.34): who actually performed the
    # write, beside the authorizing `user_id`. Nil = recorded before
    # provenance existed. `api_token_label` is snapshotted at write time —
    # revoking a token deletes its row, nilifying `api_token_id`.
    field :actor_kind, :string
    field :api_token_label, :string

    belongs_to :task, Task
    belongs_to :initiative, Initiative
    belongs_to :user, User
    belongs_to :api_token, DoIt.Accounts.ApiToken

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :task_id,
      :initiative_id,
      :user_id,
      :kind,
      :data,
      :inverse_payload,
      :undone_at,
      :actor_kind,
      :api_token_id,
      :api_token_label
    ])
    |> validate_required([:task_id, :initiative_id, :kind])
    |> validate_length(:kind, min: 1, max: 60)
    |> validate_inclusion(:actor_kind, ["browser", "api_token"])
  end
end
