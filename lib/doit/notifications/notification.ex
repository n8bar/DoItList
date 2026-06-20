defmodule DoIt.Notifications.Notification do
  @moduledoc """
  A per-user, cross-Initiative unread-feed entry (m02.08 worklist 2) — the
  unread subset of "what happened to me", distinct from the per-task Activity
  log. `kind` names the event; `data` carries the subject ids the flyout links
  to; `read_at` nil means unread.

  Schema only at this stage — generation, the flyout, and the unread dot land
  with a later agent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias DoIt.Accounts.User

  schema "notifications" do
    field :kind, :string
    field :data, :map, default: %{}
    field :read_at, :utc_datetime

    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :kind, :data, :read_at])
    |> validate_required([:user_id, :kind])
  end
end
