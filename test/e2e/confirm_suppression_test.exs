defmodule DoItWeb.E2E.ConfirmSuppressionTest do
  @moduledoc """
  §8.7.5 — machine half of §8.18: "Don't show this again" suppresses exactly
  one confirm class, persists across reload via localStorage, other classes
  keep prompting, and deletes always confirm. Native dialogs are globally
  guarded by `accept_dialogs: false` (test_helper) — any would stall a test
  into a timeout.
  """
  use PhoenixTest.Playwright.Case, async: false

  import DoItWeb.E2EHelpers

  alias DoIt.Tasks

  @moduletag :e2e

  test "suppression: per class, across reload, never for deletes", %{conn: conn} do
    user = create_user()
    initiative = create_initiative(user)

    # Three done branches, each followed by a loose leaf (Alt+→ indents under
    # the previous sibling, so each pair is one completion-flip move).
    [{p1, l1}, {p2, l2}, {p3, l3}] =
      for i <- 1..3 do
        p = create_task(user, initiative, nil, "Done #{i}")
        d = create_task(user, initiative, p, "Done #{i} leaf")
        complete!(d, user)
        l = create_task(user, initiative, nil, "Loose #{i}")
        {p, l}
      end

    # An open branch for the cascade-complete class.
    b = create_task(user, initiative, nil, "Cascade branch")
    create_task(user, initiative, b, "Cascade child")

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      # First flip prompts; check "Don't show this again" and proceed.
      |> select_task(l1)
      |> press("body", "Alt+ArrowRight")
      |> assert_has("#completion-confirm")
      |> check("Don't show this again for completion changes")
      |> click_button("Proceed")
      |> assert_has("#children-#{p1.id} > #task-#{l1.id}")
      # Second flip commits straight through, no modal.
      |> select_task(l2)
      |> press("body", "Alt+ArrowRight")
      |> assert_has("#children-#{p2.id} > #task-#{l2.id}")
      |> refute_has("#completion-confirm")

    assert Tasks.get_task!(p2.id).status == "open"

    conn =
      conn
      # Full reload: the flag must come back from localStorage.
      |> open_initiative(initiative)
      |> select_task(l3)
      |> press("body", "Alt+ArrowRight")
      |> assert_has("#children-#{p3.id} > #task-#{l3.id}")
      |> refute_has("#completion-confirm")

    conn =
      conn
      # A different class still prompts: branch checkbox = cascade-complete.
      |> PhoenixTest.Playwright.click(toggle_selector(b))
      |> assert_has("#completion-confirm", text: "Complete this branch?")
      |> click_button("Cancel")
      |> refute_has("#completion-confirm")

    # Deletes always confirm — and never offer suppression.
    conn
    |> select_task(b)
    |> press("body", "Delete")
    |> assert_has("#completion-confirm", text: "Delete task")
    |> refute_has("#completion-confirm input[name='dont_show']")
    |> click_button("Cancel")

    assert Tasks.get_task!(b.id).status == "open"
  end
end
