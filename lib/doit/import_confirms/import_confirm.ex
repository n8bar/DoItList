defmodule DoIt.ImportConfirms.ImportConfirm do
  @moduledoc """
  A server-recorded import confirm (m03.04 item 30): the readback a gated MCP
  apply parked for the operator's decision. `payload_hash` binds the confirm
  to the exact batch (sha256, computed adapter-side); `initiative_id` nil
  means a bootstrap batch homed on the account. `status` moves once, from
  `pending` to one of `approved` / `corrected` / `held` — decided only in the
  app's UI, never through the HTTP API (the agent holds the operator's
  token, so an API decision-write would let it approve its own confirm).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(pending approved corrected held)

  schema "import_confirms" do
    field :payload_hash, :string
    field :readback, :string
    field :status, :string, default: "pending"
    field :corrections, :string

    belongs_to :user, DoIt.Accounts.User
    belongs_to :initiative, DoIt.Initiatives.Initiative

    timestamps(type: :utc_datetime)
  end

  @doc "The decision vocabulary, `pending` included."
  def statuses, do: @statuses

  @doc """
  The park changeset. `user_id` / `initiative_id` are set programmatically on
  the struct (never cast); `status` starts at its `pending` default.
  """
  def changeset(confirm, attrs) do
    confirm
    |> cast(attrs, [:payload_hash, :readback])
    |> validate_required([:payload_hash, :readback])
    |> validate_length(:payload_hash, max: 128)
    |> validate_length(:readback, max: 10_000)
  end
end
