defmodule DoItWeb.E2EHelpers do
  @moduledoc """
  Shared fixtures + UI flows for the Playwright (e2e) suites in `test/e2e/`.
  Fixture functions hit the domain layer directly (shared Ecto sandbox);
  UI helpers drive the real browser and return the piped `conn`.
  """

  import ExUnit.Assertions
  import PhoenixTest

  alias DoIt.{Accounts, Initiatives, Tasks}

  @password "password123"
  def password, do: @password

  def create_user do
    {:ok, user} =
      Accounts.register_user(%{
        "email" => "e2e-#{System.unique_integer([:positive])}@example.com",
        "name" => "E2E User",
        "password" => @password
      })

    user
  end

  def create_initiative(user, name \\ "E2E Initiative") do
    {:ok, initiative} = Initiatives.create_initiative(user, %{"name" => name})
    initiative
  end

  def create_task(user, initiative, parent, title) do
    parent_id = (parent && parent.id) || initiative.root_task_id

    {:ok, task} =
      Tasks.create_task(user, %{
        "initiative_id" => initiative.id,
        "parent_id" => parent_id,
        "title" => title
      })

    task
  end

  @doc "Mark an open leaf done (ancestors auto-reconcile)."
  def complete!(task, user) do
    task = Tasks.get_task!(task.id)
    assert task.status == "open"
    {:ok, done} = Tasks.toggle_complete(task, user)
    done
  end

  def log_in(conn, user) do
    conn
    |> visit("/users/log_in")
    |> fill_in("Email", with: user.email)
    |> fill_in("Password", with: @password)
    |> click_button("Log in")
  end

  @doc "Open the initiative and wait for the LiveView socket."
  def open_initiative(conn, initiative) do
    conn
    |> visit("/initiatives/#{initiative.id}")
    |> assert_has("body .phx-connected")
  end

  @doc """
  Select a task by clicking its title; waits for the selection to land.
  Scoped to the task's own row (not descendants) and exact-matched, since a
  row click on an already-selected task would toggle it closed.
  """
  def select_task(conn, task) do
    conn
    |> PhoenixTest.Playwright.click(
      "#task-#{task.id} > [data-task-row] span",
      task.title,
      exact: true
    )
    |> assert_has("li[data-selected='#{task.id}']")
  end

  # Scoped to the task's own row — a bare descendant selector would also
  # match the toggles of nested children.
  def toggle_selector(task), do: "#task-#{task.id} > [data-task-row] [data-complete-toggle]"

  def assert_done(conn, task),
    do: assert_has(conn, "#{toggle_selector(task)}[aria-pressed='true']")

  def assert_open(conn, task),
    do: assert_has(conn, "#{toggle_selector(task)}[aria-pressed='false']")

  def activity_count, do: DoIt.Repo.aggregate(DoIt.Tasks.ActivityEvent, :count)
end
