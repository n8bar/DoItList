defmodule DoIt.ImportDeclarationsTest do
  @moduledoc """
  First-import declarations (m03.04 2.8.10): Initiative-homed, TTL-free,
  first-declaration-wins — the server-side row the MCP adapter records on an
  accepted first import and checks every later chunk against.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, ImportDeclarations, Initiatives}

  defp owner_and_initiative do
    {:ok, owner} =
      Accounts.register_user(%{
        "email" => "owner-#{System.unique_integer([:positive])}@example.com",
        "username" => "owner-#{System.unique_integer([:positive])}",
        "name" => "Owner",
        "password" => "password123"
      })

    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Import"})
    {owner, ini}
  end

  test "records once and reads back; the first declaration wins" do
    {_owner, ini} = owner_and_initiative()

    attrs = %{
      "source_total" => 20,
      "source_completed" => 5,
      "excluded_count" => 2,
      "exclusions" => "2 × appendix notes",
      "ordering" => "outline"
    }

    assert {:ok, declaration} = ImportDeclarations.record(ini.id, attrs)
    assert declaration.source_total == 20
    assert declaration.source_completed == 5
    assert declaration.excluded_count == 2
    assert declaration.exclusions == "2 × appendix notes"
    assert declaration.ordering == "outline"

    assert ImportDeclarations.for_initiative(ini.id).id == declaration.id

    # A re-record returns the standing row unchanged — never a rewrite.
    assert {:ok, same} = ImportDeclarations.record(ini.id, %{attrs | "source_total" => 99})
    assert same.id == declaration.id
    assert same.source_total == 20
  end

  test "an undeclared Initiative reads nil" do
    {_owner, ini} = owner_and_initiative()
    assert ImportDeclarations.for_initiative(ini.id) == nil
  end

  test "arithmetic sanity lives in the changeset — completed and exclusions within the total" do
    {_owner, ini} = owner_and_initiative()

    assert {:error, changeset} =
             ImportDeclarations.record(ini.id, %{"source_total" => 5, "source_completed" => 7})

    assert %{source_completed: _} = errors_on(changeset)

    assert {:error, changeset} =
             ImportDeclarations.record(ini.id, %{
               "source_total" => 5,
               "source_completed" => 0,
               "excluded_count" => 6
             })

    assert %{excluded_count: _} = errors_on(changeset)

    assert {:error, changeset} = ImportDeclarations.record(ini.id, %{"source_total" => 0})
    assert %{source_total: _} = errors_on(changeset)
  end
end
