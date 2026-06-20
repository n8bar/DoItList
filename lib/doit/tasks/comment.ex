defmodule DoIt.Tasks.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Tasks.Task

  schema "comments" do
    field :body, :string
    # Soft-delete (m02.06 item 14.5): set when an undo removes the comment,
    # cleared on redo. Reads filter `deleted_at IS NULL`.
    field :deleted_at, :utc_datetime

    belongs_to :task, Task
    belongs_to :user, User
    # Soft-delete "who" (m02.08 worklist 3 item 2). Set programmatically by
    # Tasks.delete_comment/2 — never cast from user params. Its presence (vs. a
    # bare deleted_at) marks a lifecycle tombstone, distinct from an undo-removal.
    belongs_to :deleted_by, User

    has_many :versions, DoIt.Tasks.CommentVersion

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :task_id, :user_id])
    |> validate_required([:body, :task_id, :user_id])
    |> validate_length(:body, min: 1, max: 4000)
  end
end
