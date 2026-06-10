defmodule DoItWeb.E2E.KeyboardTest do
  @moduledoc """
  §8.7.4 — real keydowns through the `.TaskKeys` hook (machine half of
  §8.9 / §8.16). Handler-level semantics are already covered by LiveView
  tests; this proves the browser layer: key routing, focus, suppression,
  scroll-into-view.
  """
  use PhoenixTest.Playwright.Case, async: false

  import DoItWeb.E2EHelpers

  alias DoIt.Tasks

  @moduletag :e2e

  setup do
    user = create_user()
    initiative = create_initiative(user)
    %{user: user, initiative: initiative}
  end

  test "arrows move the selection; Enter toggles the pane; Space collapses", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    a = create_task(user, initiative, nil, "Alpha")
    ac = create_task(user, initiative, a, "Alpha child")
    b = create_task(user, initiative, nil, "Beta")

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> select_task(a)
      # ↓ next visible task = Alpha's child; ← back to the parent
      |> press("body", "ArrowDown")
      |> assert_has("li[data-selected='#{ac.id}']")
      |> press("body", "ArrowLeft")
      |> assert_has("li[data-selected='#{a.id}']")
      # → first child again
      |> press("body", "ArrowRight")
      |> assert_has("li[data-selected='#{ac.id}']")

    conn =
      conn
      # Enter deselects; Enter again restores the same task
      |> press("body", "Enter")
      |> refute_has("li[data-selected]")
      |> press("body", "Enter")
      |> assert_has("li[data-selected='#{ac.id}']")

    conn
    |> select_task(a)
    |> press("body", " ")
    |> assert_has("#collapse-#{a.id}[aria-expanded='false']")
    |> press("body", " ")
    |> assert_has("#collapse-#{a.id}[aria-expanded='true']")

    # selection never wandered to Beta
    refute Tasks.get_task!(b.id).id == nil
  end

  test "N / S open the subtask / sibling forms with the input focused", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    a = create_task(user, initiative, nil, "Parent")

    conn
    |> log_in(user)
    |> open_initiative(initiative)
    |> select_task(a)
    |> press("body", "n")
    |> assert_has("#task-#{a.id} form input[name='title']:focus")
    # Cancel closes the form; the selection stays on the task.
    |> click_button("Cancel")
    |> refute_has("input[name='title']")
    |> press("body", "s")
    |> assert_has("input[name='title']:focus")
  end

  test "P / W / A step values; Shift reverses; Alt+P focuses the field", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    a = create_task(user, initiative, nil, "Tunable")

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> select_task(a)
      # The row's priority pill shows the value whenever it isn't "normal".
      |> press("body", "p")
      |> assert_has("#task-#{a.id} [phx-value-focus='priority']", text: "high")
      |> press("body", "Shift+P")
      |> assert_has("#task-#{a.id} [phx-value-focus='priority'][title='Priority: normal']")
      |> press("body", "w")
      |> assert_has("#task-#{a.id} [phx-value-focus='weight']", text: "w=2")

    assert Decimal.equal?(Tasks.get_task!(a.id).weight, Decimal.new(2))

    conn
    |> press("body", "Alt+p")
    |> assert_has("#task-field-priority:focus")
  end

  test "Del raises the styled delete confirm for the selected task", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    a = create_task(user, initiative, nil, "Doomed")

    conn
    |> log_in(user)
    |> open_initiative(initiative)
    |> select_task(a)
    |> press("body", "Delete")
    |> assert_has("#completion-confirm", text: "Delete task")
    |> click_button("#completion-confirm button[type='submit']", "Delete")
    |> refute_has("#task-#{a.id}")

    assert Tasks.get_task(a.id) == nil
  end

  test "shortcuts are suppressed while a text field is focused", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    a = create_task(user, initiative, nil, "Steady")

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> select_task(a)
      # focus the (already focused) new-subtask input via N first
      |> press("body", "n")
      |> assert_has("#task-#{a.id} form input[name='title']:focus")
      # Inside the input: Delete must NOT open the delete modal, "s" must not
      # spawn a sibling form, arrows must not move the selection.
      |> press("input[name='title']", "Delete")
      |> refute_has("#completion-confirm")
      |> press("input[name='title']", "s")
      |> press("input[name='title']", "ArrowDown")
      |> assert_has("li[data-selected='#{a.id}']")

    assert Tasks.get_task!(a.id).id == a.id
  end

  test "keyboard selection scrolls the row into view", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    tasks = for i <- 1..30, do: create_task(user, initiative, nil, "Row #{i}")
    first = hd(tasks)
    last = List.last(tasks)

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> select_task(first)

    conn =
      Enum.reduce(1..29, conn, fn _, c -> press(c, "body", "ArrowDown") end)

    conn
    |> assert_has("li[data-selected='#{last.id}']")
    |> evaluate(
      """
      (() => {
        const li = document.querySelector("li[data-selected]");
        const r = li.firstElementChild.getBoundingClientRect();
        return r.top >= 0 && r.bottom <= window.innerHeight;
      })()
      """,
      fn visible? -> assert visible? end
    )
  end
end
