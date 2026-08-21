defmodule DoIt.ImportApprovals.ImportApproval do
  @moduledoc """
  A server-recorded import approval (m03.04 2.8.8): the open-only bootstrap
  import the MCP adapter refused, parked for the operator's one-click call.
  `payload_hash` binds the approval to the exact batch (sha256, computed
  adapter-side); always account-homed — a bootstrap batch's Initiative
  doesn't exist yet. `status` moves once, from `pending` to `approved` or
  `dismissed` — decided only in the app's UI, never through the HTTP API
  (the agent holds the operator's token, so an API decision-write would let
  it approve its own import).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending approved dismissed)

  schema "import_approvals" do
    field :payload_hash, :string
    field :task_count, :integer
    field :initiative_name, :string
    field :status, :string, default: "pending"

    belongs_to :user, DoIt.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc "The decision vocabulary, `pending` included."
  def statuses, do: @statuses

  @doc """
  The park changeset. `user_id` is set programmatically on the struct (never
  cast); `status` starts at its `pending` default.
  """
  def changeset(approval, attrs) do
    approval
    |> cast(attrs, [:payload_hash, :task_count, :initiative_name])
    |> validate_required([:payload_hash, :task_count, :initiative_name])
    |> validate_length(:payload_hash, max: 128)
    |> validate_length(:initiative_name, max: 255)
    |> validate_number(:task_count, greater_than: 0)
  end
end
