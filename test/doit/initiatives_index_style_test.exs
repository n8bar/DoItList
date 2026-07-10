defmodule DoIt.InitiativesIndexStyleTest do
  @moduledoc """
  m02.07 item 1.7.2 — the per-Initiative task-index style: it defaults to
  "none", casts/validates through the changeset, and persists. m03.03 O&C 6.1
  — a style change broadcasts an Initiative update so other sessions re-fetch
  `@initiative` and re-label (no tree reload; the tasks didn't change).
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives, Tasks}

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

  test "a style change broadcasts an Initiative update on the Initiative topic" do
    {:ok, init} = Initiatives.create_initiative(user("Eve"), %{"name" => "Five"})
    :ok = Tasks.subscribe(init.id)

    {:ok, updated} = Initiatives.update_initiative(init, %{"index_style" => "roman"})

    assert_receive {:initiative_updated, initiative_id}, 1000
    assert initiative_id == updated.id
  end

  test "an update that leaves the style alone broadcasts nothing" do
    {:ok, init} = Initiatives.create_initiative(user("Fay"), %{"name" => "Six"})
    :ok = Tasks.subscribe(init.id)

    {:ok, _} = Initiatives.update_initiative(init, %{"name" => "Six, renamed"})

    refute_receive {:initiative_updated, _}, 100
  end

  test "an unrecognized style is rejected" do
    {:ok, init} = Initiatives.create_initiative(user("Dee"), %{"name" => "Four"})

    assert {:error, changeset} =
             Initiatives.update_initiative(init, %{"index_style" => "bogus"})

    assert "is invalid" in errors_on(changeset).index_style
  end
end
