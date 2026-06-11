defmodule DoItWeb.E2E.CompletionConfirmTest do
  @moduledoc """
  §8.7.3 — machine half of the completion-confirm modal checks (§8.8).
  Scenarios 1/2 ride the keyboard reorg path, scenario 3 a real mouse drag;
  all three are the same preview → confirm pipeline as any move.
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

  test "scenario 1: moving an incomplete leaf under a done branch confirms, Proceed unchecks it",
       %{conn: conn, user: user, initiative: initiative} do
    p = create_task(user, initiative, nil, "Done branch")
    d = create_task(user, initiative, p, "Done leaf")
    complete!(d, user)
    l = create_task(user, initiative, nil, "Loose leaf")

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> assert_done(p)
      |> select_task(l)
      |> press("body", "Alt+ArrowLeft")

    # Alt+← on a top-level task is one of the blocked no-ops: nothing happens.
    conn = refute_has(conn, "#completion-confirm")

    conn =
      conn
      |> press("body", "Alt+ArrowRight")
      |> assert_has("#completion-confirm", text: "Done branch")

    # Gated: nothing moved while the modal is up.
    assert Tasks.get_task!(l.id).parent_id == initiative.root_task_id

    conn
    |> click_button("Proceed")
    |> assert_has("#children-#{p.id} > #task-#{l.id}")
    |> assert_open(p)
  end

  test "scenario 2: dedenting the last incomplete child confirms, Proceed checks the branch",
       %{conn: conn, user: user, initiative: initiative} do
    b = create_task(user, initiative, nil, "Almost done")
    d = create_task(user, initiative, b, "Done part")
    complete!(d, user)
    l = create_task(user, initiative, b, "Open part")

    conn
    |> log_in(user)
    |> open_initiative(initiative)
    |> assert_open(b)
    |> select_task(l)
    |> press("body", "Alt+ArrowLeft")
    |> assert_has("#completion-confirm", text: "Almost done")
    |> click_button("Proceed")
    |> assert_done(b)

    assert Tasks.get_task!(l.id).parent_id == initiative.root_task_id
  end

  test "scenario 3: dragging the last incomplete child into a done branch lists both flips",
       %{conn: conn, user: user, initiative: initiative} do
    a = create_task(user, initiative, nil, "Source branch")
    ad = create_task(user, initiative, a, "Source done")
    complete!(ad, user)
    l = create_task(user, initiative, a, "Moving leaf")

    p = create_task(user, initiative, nil, "Dest branch")
    pd = create_task(user, initiative, p, "Dest done")
    complete!(pd, user)

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> assert_done(p)
      |> assert_open(a)
      |> drag("#drag-#{l.id}", to: "#task-#{p.id} > [data-task-row]")
      |> assert_has("#completion-confirm", text: "Source branch")
      |> assert_has("#completion-confirm", text: "Dest branch")
      # §8.20 / .03.07.14: the optimistic placement HOLDS while the modal
      # decides — the row sits under the destination, not snapped home.
      |> assert_has("#children-#{p.id} > #task-#{l.id}")
      |> click_button("Proceed")

    conn
    |> assert_done(a)
    |> assert_open(p)

    assert Tasks.get_task!(l.id).parent_id == p.id
  end

  test "drag cancel: the held placement reverts home (.03.07.14)",
       %{conn: conn, user: user, initiative: initiative} do
    a = create_task(user, initiative, nil, "Source branch")
    ad = create_task(user, initiative, a, "Source done")
    complete!(ad, user)
    l = create_task(user, initiative, a, "Moving leaf")

    p = create_task(user, initiative, nil, "Dest branch")
    pd = create_task(user, initiative, p, "Dest done")
    complete!(pd, user)

    conn
    |> log_in(user)
    |> open_initiative(initiative)
    |> drag("#drag-#{l.id}", to: "#task-#{p.id} > [data-task-row]")
    |> assert_has("#completion-confirm")
    |> assert_has("#children-#{p.id} > #task-#{l.id}")
    |> click_button("Cancel")
    |> refute_has("#completion-confirm")
    |> assert_has("#children-#{a.id} > #task-#{l.id}")

    assert Tasks.get_task!(l.id).parent_id == a.id
    assert Tasks.get_task!(a.id).status == "open"
  end

  test "cancel: tree state and activity log untouched", %{
    conn: conn,
    user: user,
    initiative: initiative
  } do
    p = create_task(user, initiative, nil, "Done branch")
    d = create_task(user, initiative, p, "Done leaf")
    complete!(d, user)
    l = create_task(user, initiative, nil, "Loose leaf")

    conn =
      conn
      |> log_in(user)
      |> open_initiative(initiative)
      |> select_task(l)

    events_before = activity_count()

    conn
    |> press("body", "Alt+ArrowRight")
    |> assert_has("#completion-confirm")
    |> click_button("Cancel")
    |> refute_has("#completion-confirm")
    |> assert_done(p)

    assert Tasks.get_task!(l.id).parent_id == initiative.root_task_id
    assert activity_count() == events_before
  end

  test "a confirmed flip broadcasts to a second tab",
       %{conn: conn, user: user, initiative: initiative} = context do
    b = create_task(user, initiative, nil, "Watched branch")
    d = create_task(user, initiative, b, "Done part")
    complete!(d, user)
    l = create_task(user, initiative, b, "Open part")

    # Second browser context = second tab (own cookies, so it logs in too).
    # The ExUnit context carries the launched browser_id, so the Case's own
    # setup builds another session against the same browser.
    [conn: conn2] = PhoenixTest.Playwright.Case.do_setup(context)

    conn2 =
      conn2
      |> log_in(user)
      |> open_initiative(initiative)
      |> assert_open(b)

    conn
    |> log_in(user)
    |> open_initiative(initiative)
    |> select_task(l)
    |> press("body", "Alt+ArrowLeft")
    |> assert_has("#completion-confirm")
    |> click_button("Proceed")
    |> assert_done(b)

    # PubSub fan-out: the other tab sees the flip without any interaction.
    assert_done(conn2, b)
  end
end
