defmodule DoIt.Tasks.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User
  alias DoIt.Tasks.Task

  schema "comments" do
    field :body, :string

    belongs_to :task, Task
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :task_id, :user_id])
    |> validate_required([:body, :task_id, :user_id])
    |> validate_length(:body, min: 1, max: 4000)
  end
end
