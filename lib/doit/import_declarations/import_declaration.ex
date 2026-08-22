defmodule DoIt.ImportDeclarations.ImportDeclaration do
  @moduledoc """
  An Initiative's first-import declaration (m03.04 2.8.10) — the structured
  statement the MCP adapter interviews out of an importing agent and validates
  arithmetically: the source's item total, its completed count, how many items
  the import excludes (`excluded_count`, the arithmetic's number) with the
  verbatim reasons (`exclusions`, prose for the record), and the source's
  ordering scheme. One row per Initiative, recorded on the first accepted
  declaration and never expiring — it is the import's on-record statement, so
  a silent narrowing later reads against it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "import_declarations" do
    field :source_total, :integer
    field :source_completed, :integer
    field :excluded_count, :integer, default: 0
    field :exclusions, :string
    field :ordering, :string

    belongs_to :initiative, DoIt.Initiatives.Initiative

    timestamps(type: :utc_datetime)
  end

  @doc """
  The record changeset. `initiative_id` is set programmatically on the struct
  (never cast). The arithmetic sanity lives here too: totals non-negative,
  completed and exclusions each within the total.
  """
  def changeset(declaration, attrs) do
    declaration
    |> cast(attrs, [:source_total, :source_completed, :excluded_count, :exclusions, :ordering])
    |> validate_required([:source_total, :source_completed])
    |> validate_number(:source_total, greater_than: 0)
    |> validate_number(:source_completed, greater_than_or_equal_to: 0)
    |> validate_number(:excluded_count, greater_than_or_equal_to: 0)
    |> validate_within_total(:source_completed)
    |> validate_within_total(:excluded_count)
    |> validate_length(:exclusions, max: 2_000)
    |> validate_length(:ordering, max: 255)
    |> unique_constraint(:initiative_id)
  end

  defp validate_within_total(changeset, field) do
    total = get_field(changeset, :source_total)

    validate_change(changeset, field, fn ^field, value ->
      if is_integer(total) and value > total do
        [{field, "cannot exceed source_total"}]
      else
        []
      end
    end)
  end
end
