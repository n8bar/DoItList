defmodule DoIt.InitiativesIndexStyleTest do
  @moduledoc """
  m02.07 item 1.7.2 — the per-Initiative task-index style: it defaults to
  "none", casts/validates through the changeset, and persists.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives}

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => name,
        "password" => "password123"
      })

    u
  end

  test "a new Initiative defaults to the \"none\" index style" do
    {:ok, init} = Initiatives.create_initiative(user("Ann"), %{"name" => "One"})
    assert init.index_style == "none"
  end

  test "update + persist a recognized style" do
    {:ok, init} = Initiatives.create_initiative(user("Bob"), %{"name" => "Two"})

    {:ok, updated} = Initiatives.update_initiative(init, %{"index_style" => "outline"})
    assert updated.index_style == "outline"

    # Survives a reload from the DB.
    assert Initiatives.get_initiative(init.id).index_style == "outline"
  end

  test "every recognized style is accepted" do
    {:ok, init} = Initiatives.create_initiative(user("Cal"), %{"name" => "Three"})

    for style <- ~w(none outline numerical roman alphabetical) do
      assert {:ok, %{index_style: ^style}} =
               Initiatives.update_initiative(init, %{"index_style" => style})
    end
  end

  test "an unrecognized style is rejected" do
    {:ok, init} = Initiatives.create_initiative(user("Dee"), %{"name" => "Four"})

    assert {:error, changeset} =
             Initiatives.update_initiative(init, %{"index_style" => "bogus"})

    assert "is invalid" in errors_on(changeset).index_style
  end
end
