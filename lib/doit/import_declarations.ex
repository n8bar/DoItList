defmodule DoIt.ImportDeclarations do
  @moduledoc """
  First-import declarations (m03.04 2.8.10), Initiative-homed and TTL-free.
  The MCP adapter records a declaration once the arithmetic accepts an
  Initiative's first import, and consults it back (riding the `task_count`
  read) to check every later chunk of the same import. First declaration
  wins: a re-record against a declared Initiative returns the standing row
  unchanged — the declaration binds the WHOLE import, so it never silently
  rewrites.
  """

  import Ecto.Query, warn: false

  alias DoIt.ImportDeclarations.ImportDeclaration
  alias DoIt.Repo

  @doc """
  Record `initiative_id`'s first-import declaration. Idempotent per the
  moduledoc: a standing declaration is returned as-is (`{:ok, declaration}`),
  never overwritten; otherwise the row inserts. A losing insert race reloads
  the winner.
  """
  def record(initiative_id, attrs) when is_integer(initiative_id) do
    case for_initiative(initiative_id) do
      %ImportDeclaration{} = declaration ->
        {:ok, declaration}

      nil ->
        %ImportDeclaration{initiative_id: initiative_id}
        |> ImportDeclaration.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:error, %Ecto.Changeset{errors: errors} = changeset} ->
            if Keyword.has_key?(errors, :initiative_id),
              do: {:ok, for_initiative(initiative_id)},
              else: {:error, changeset}

          other ->
            other
        end
    end
  end

  @doc "The Initiative's standing declaration, or nil."
  def for_initiative(initiative_id) when is_integer(initiative_id) do
    Repo.get_by(ImportDeclaration, initiative_id: initiative_id)
  end
end
