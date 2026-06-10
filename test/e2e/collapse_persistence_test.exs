defmodule DoItWeb.E2E.CollapsePersistenceTest do
  @moduledoc """
  Regression net for the §8.11 finding: applying a sort mode must not expand
  collapsed branches — collapse state lives client-side (localStorage) and is
  re-applied across re-renders.
  """
  use PhoenixTest.Playwright.Case, async: false

  import DoItWeb.E2EHelpers

  @moduletag :e2e

  test "collapsed branches stay collapsed through a sort", %{conn: conn} do
    user = create_user()
    initiative = create_initiative(user)

    # Sorted branch with mixed titles; one child is itself a collapsible
    # branch (the reorder moves its <li>). Plus a separate collapsed branch.
    sorted = create_task(user, initiative, nil, "Sorted branch")
    create_task(user, initiative, sorted, "charlie")
    create_task(user, initiative, sorted, "alpha")
    inner = create_task(user, initiative, sorted, "bravo")
    create_task(user, initiative, inner, "bravo child")

    folded = create_task(user, initiative, nil, "Folded branch")
    create_task(user, initiative, folded, "hidden child")

    conn
    |> log_in(user)
    |> open_initiative(initiative)
    # Collapse the unrelated branch and the branch inside the sorted one.
    |> PhoenixTest.Playwright.click("#collapse-#{folded.id}")
    |> assert_has("#children-#{folded.id}.collapsed-peek")
    |> PhoenixTest.Playwright.click("#collapse-#{inner.id}")
    |> assert_has("#children-#{inner.id}.collapsed-peek")
    # Collapse the sorted branch itself, then sort it from the Details pane —
    # the reorder rewrites exactly the <ul> that's collapsed.
    |> select_task(sorted)
    |> PhoenixTest.Playwright.click("#collapse-#{sorted.id}")
    |> assert_has("#children-#{sorted.id}.collapsed-peek")
    |> select("Sort children by", option: "Alphabetical")
    |> assert_has("#children-#{sorted.id} > li:first-child", text: "alpha")
    # Everything must still be collapsed.
    |> assert_has("#children-#{sorted.id}.collapsed-peek")
    |> assert_has("#children-#{inner.id}.collapsed-peek")
    |> assert_has("#children-#{folded.id}.collapsed-peek")
  end

  test "collapsed branches survive reorders and being moved themselves", %{conn: conn} do
    user = create_user()
    initiative = create_initiative(user)

    parent = create_task(user, initiative, nil, "Parent")
    inner = create_task(user, initiative, parent, "Inner branch")
    create_task(user, initiative, inner, "inner child")
    sib = create_task(user, initiative, parent, "Sibling")

    dest = create_task(user, initiative, nil, "Dest branch")
    create_task(user, initiative, dest, "dest child")

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> PhoenixTest.Playwright.click("#collapse-#{inner.id}")
      |> assert_has("#children-#{inner.id}.collapsed-peek")
      # Keyboard reorder around the collapsed branch.
      |> select_task(sib)
      |> press("body", "Alt+ArrowUp")
      |> assert_has("#children-#{parent.id} > li:first-child#task-#{sib.id}")
      |> assert_has("#children-#{inner.id}.collapsed-peek")

    # Drag the collapsed branch itself into another parent — the optimistic
    # client-side move is the patch path most likely to drop client classes.
    conn
    |> drag("#drag-#{inner.id}", to: "#task-#{dest.id} > [data-task-row]")
    |> assert_has("#children-#{dest.id} #task-#{inner.id}")
    |> assert_has("#children-#{inner.id}.collapsed-peek")
  end
end
