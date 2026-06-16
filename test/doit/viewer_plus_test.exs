defmodule DoIt.ViewerPlusTest do
  @moduledoc """
  m02.05 item 12.6 — Viewer+. The assignment-derived reach: a viewer who is a
  task's direct (primary) assignee leads that task and its whole subtree.
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

  defp task(owner, initiative, parent, title, attrs \\ %{}) do
    parent_id = (parent && parent.id) || initiative.root_task_id

    {:ok, t} =
      Tasks.create_task(
        owner,
        Map.merge(%{"initiative_id" => initiative.id, "parent_id" => parent_id, "title" => title}, attrs)
      )

    t
  end

  test "viewer_plus_led_ids = the assignee's task + all descendants, nothing else" do
    owner = user("Owner")
    viewer = user("Viewer")
    {:ok, init} = Initiatives.create_initiative(owner, %{"name" => "Init"})
    {:ok, _} = Initiatives.add_member(init.id, viewer.id, "viewer")

    a = task(owner, init, nil, "A")
    b = task(owner, init, a, "B", %{"assignee_id" => viewer.id})
    c = task(owner, init, b, "C")
    _d = task(owner, init, nil, "D")

    led = Tasks.viewer_plus_led_ids(init.id, viewer.id)

    # B is led (direct assignee) and C inherits (descendant); A (ancestor) and
    # D (unrelated) are not.
    assert MapSet.member?(led, b.id)
    assert MapSet.member?(led, c.id)
    refute MapSet.member?(led, a.id)

    # Someone who is the primary of nothing leads nothing.
    assert Tasks.viewer_plus_led_ids(init.id, owner.id) |> MapSet.size() == 0
  end

  test "viewer_staff_pool = the led task's co-assignees, for its descendants only" do
    owner = user("Owner")
    viewer = user("Viewer")
    x = user("X")
    y = user("Y")
    {:ok, init} = Initiatives.create_initiative(owner, %{"name" => "Init"})

    a = task(owner, init, nil, "A")
    b = task(owner, init, a, "B", %{"assignee_id" => viewer.id})
    c = task(owner, init, b, "C")
    d = task(owner, init, nil, "D")

    # Owner hands the led task B a pool of {X, Y}.
    {:ok, _} = Tasks.add_co_assignee(b, owner, x.id)
    {:ok, _} = Tasks.add_co_assignee(b, owner, y.id)

    # A descendant of B draws from B's co-assignees.
    assert Tasks.viewer_staff_pool(viewer.id, c) == MapSet.new([x.id, y.id])

    # The led task itself is off-limits (its co-list is owner-seeded).
    assert Tasks.viewer_staff_pool(viewer.id, b) == nil

    # Tasks outside the led subtree give no pool at all.
    assert Tasks.viewer_staff_pool(viewer.id, a) == nil
    assert Tasks.viewer_staff_pool(viewer.id, d) == nil
  end

  test "viewer_staff_pool shrinks to the NEAREST led ancestor's co-assignees" do
    owner = user("Owner")
    viewer = user("Viewer")
    x = user("X")
    y = user("Y")
    {:ok, init} = Initiatives.create_initiative(owner, %{"name" => "Init"})

    b = task(owner, init, nil, "B", %{"assignee_id" => viewer.id})
    c = task(owner, init, b, "C")
    # The viewer also directly leads E (deeper), with a narrower pool {X}.
    e = task(owner, init, c, "E", %{"assignee_id" => viewer.id})
    f = task(owner, init, e, "F")

    {:ok, _} = Tasks.add_co_assignee(b, owner, x.id)
    {:ok, _} = Tasks.add_co_assignee(b, owner, y.id)
    {:ok, _} = Tasks.add_co_assignee(e, owner, x.id)

    # Between B and E, the pool is B's {X, Y}.
    assert Tasks.viewer_staff_pool(viewer.id, c) == MapSet.new([x.id, y.id])

    # Under E, the nearest led ancestor is E, so the pool narrows to {X}.
    assert Tasks.viewer_staff_pool(viewer.id, f) == MapSet.new([x.id])
  end
end
