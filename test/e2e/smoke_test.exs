defmodule DoItWeb.E2E.SmokeTest do
  @moduledoc """
  Proves the Playwright rig end to end (M02 Arc 3 §8.7.2): real browser,
  login through the actual form, LiveView connect, row selection, and a leaf
  completion toggle round-tripped through the server.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias DoIt.{Accounts, Initiatives, Tasks}

  @moduletag :e2e

  @password "password123"

  setup do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "e2e-#{System.unique_integer([:positive])}@example.com",
        "name" => "E2E User",
        "password" => @password
      })

    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => "E2E Initiative"})

    %{user: user, initiative: initiative}
  end

  defp create_task(user, initiative, parent, title) do
    parent_id = (parent && parent.id) || initiative.root_task_id

    {:ok, task} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title
      })

    task
  end

  test "log in, open the tree, select a task, complete a leaf", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    leaf = create_task(user, initiative, nil, "E2E leaf")
    # A second incomplete sibling so completing the leaf flips no ancestor
    # (keeps the completion-confirm modal out of the smoke test).
    create_task(user, initiative, nil, "E2E other")

    conn
    |> visit("/users/log_in")
    |> fill_in("Email", with: user.email)
    |> fill_in("Password", with: @password)
    |> click_button("Log in")
    |> visit("/initiatives/#{initiative.id}")
    |> assert_has("body .phx-connected")
    |> assert_has("#task-#{leaf.id}", text: "E2E leaf")
    |> click("#task-#{leaf.id} span", "E2E leaf")
    |> assert_has("#delete-task-btn")
    |> click("#task-#{leaf.id} [data-complete-toggle]")
    |> assert_has("#task-#{leaf.id} [data-complete-toggle][aria-pressed=true]")

    assert Tasks.get_task!(leaf.id).status == "done"
  end
end
