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
    # The batch's deepest-branch snapshot, %{"nodes" => [%{title, description,
    # depth}]} — the card shows content instead of our classification
    # (m03.04 3.1.9.2). A map, not a bare list, so later fields need no migration.
    field :sample, :map
    # The operator's words on a rejection, handed to the agent (3.1.9.2).
    field :decision_reason, :string

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
    |> cast(attrs, [:payload_hash, :task_count, :initiative_name, :sample])
    |> validate_required([:payload_hash, :task_count, :initiative_name])
    |> validate_length(:payload_hash, max: 128)
    |> validate_length(:initiative_name, max: 255)
    |> validate_number(:task_count, greater_than: 0)
  end

  @doc """
  The decision changeset — `status` plus the operator's optional words. The
  reason is theirs, typed in the app; blank collapses to nil so the agent is
  told the operator gave none rather than shown an empty quote.
  """
  def decision_changeset(approval, status, reason) do
    approval
    |> change(status: status)
    |> put_change(:decision_reason, presence(reason))
    |> validate_length(:decision_reason, max: 500)
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_), do: nil
end
