defmodule DoIt.Tasks.SortTest do
  @moduledoc """
  Pure tests for `DoIt.Tasks.Sort.apply/3`. These do NOT touch the database;
  they exercise the sort engine against hand-built `%Task{}` structs.
  """
  use ExUnit.Case, async: true

  alias DoIt.Tasks.{Sort, Task}

  @gap Sort.sort_gap()

  defp task(id, opts) do
    %Task{
      id: id,
      title: Keyword.get(opts, :title, "task-#{id}"),
      status: Keyword.get(opts, :status, "open"),
      priority: Keyword.get(opts, :priority, "normal"),
      computed_progress: Keyword.get(opts, :computed_progress, 0),
      weight: Keyword.get(opts, :weight, Decimal.new("1.0")),
      sort_order: Keyword.get(opts, :sort_order, 0),
      inserted_at: Keyword.get(opts, :inserted_at, DateTime.utc_now()),
      updated_at: Keyword.get(opts, :updated_at, DateTime.utc_now())
    }
  end

  describe "apply/3 — short-circuit cases" do
    test "empty list returns []" do
      assert Sort.apply([], "alphabetical") == []
      assert Sort.apply([], "manual") == []
      assert Sort.apply([], "alphabetical", true) == []
    end

    test "single-element list returns unchanged (mode and direction irrelevant)" do
      t = task(1, title: "only", sort_order: 42)

      for mode <- ~w(manual alphabetical completion computed_progress priority created updated) do
        assert Sort.apply([t], mode) == [t]
        assert Sort.apply([t], mode, true) == [t]
      end
    end

    test "manual mode on a multi-element list returns input unchanged (no re-stamp)" do
      a = task(1, title: "Z", sort_order: 999)
      b = task(2, title: "A", sort_order: 1)
      c = task(3, title: "M", sort_order: 50_000)

      assert Enum.map(Sort.apply([a, b, c], "manual"), & &1.id) == [1, 2, 3]
      assert Enum.map(Sort.apply([a, b, c], "manual"), & &1.sort_order) == [999, 1, 50_000]
      # reverse? has no effect on manual.
      assert Sort.apply([a, b, c], "manual", true) == [a, b, c]
    end

    test "an unknown/legacy mode is treated as manual (no crash, order preserved)" do
      a = task(1, title: "Z", sort_order: 999)
      b = task(2, title: "A", sort_order: 1)

      # A stray value (e.g. a sort_mode left over from a renamed scheme) must
      # never crash the sort engine — it degrades to manual.
      assert Sort.apply([a, b], "status") == [a, b]
      assert Sort.apply([a, b], "bogus", true) == [a, b]
    end
  end

  describe "apply/3 — alphabetical" do
    test "sorts case-insensitively ascending and stamps sort_order" do
      tasks = [
        task(1, title: "banana"),
        task(2, title: "Apple"),
        task(3, title: "cherry")
      ]

      result = Sort.apply(tasks, "alphabetical")

      assert Enum.map(result, & &1.title) == ["Apple", "banana", "cherry"]
      assert Enum.map(result, & &1.sort_order) == [1 * @gap, 2 * @gap, 3 * @gap]
    end

    test "id tiebreaker for matching titles — lower id first regardless of input order" do
      a = task(10, title: "same")
      b = task(5, title: "same")
      c = task(7, title: "same")

      for input <- [[a, b, c], [c, a, b], [b, c, a]] do
        assert Sort.apply(input, "alphabetical") |> Enum.map(& &1.id) == [5, 7, 10]
      end
    end
  end

  describe "apply/3 — completion" do
    test "orders open → in_progress → done and stamps sort_order" do
      tasks = [
        task(1, status: "done"),
        task(2, status: "open"),
        task(3, status: "in_progress")
      ]

      result = Sort.apply(tasks, "completion")

      assert Enum.map(result, & &1.status) == ["open", "in_progress", "done"]
      assert Enum.map(result, & &1.sort_order) == [@gap, 2 * @gap, 3 * @gap]
    end

    test "id tiebreaker for matching status — lower id first regardless of input order" do
      a = task(30, status: "open")
      b = task(10, status: "open")
      c = task(20, status: "open")

      for input <- [[a, b, c], [c, b, a], [b, a, c]] do
        assert Sort.apply(input, "completion") |> Enum.map(& &1.id) == [10, 20, 30]
      end
    end
  end

  describe "apply/3 — computed_progress" do
    test "orders descending (most progress first) and stamps sort_order" do
      tasks = [
        task(1, computed_progress: 25),
        task(2, computed_progress: 100),
        task(3, computed_progress: 0),
        task(4, computed_progress: 60)
      ]

      result = Sort.apply(tasks, "computed_progress")

      assert Enum.map(result, & &1.computed_progress) == [100, 60, 25, 0]
      assert Enum.map(result, & &1.sort_order) == [@gap, 2 * @gap, 3 * @gap, 4 * @gap]
    end

    test "id tiebreaker for matching progress — lower id first regardless of input order" do
      a = task(8, computed_progress: 50)
      b = task(2, computed_progress: 50)
      c = task(5, computed_progress: 50)

      for input <- [[a, b, c], [c, a, b], [b, c, a]] do
        assert Sort.apply(input, "computed_progress") |> Enum.map(& &1.id) == [2, 5, 8]
      end
    end
  end

  describe "apply/3 — priority" do
    test "orders high → normal → low and stamps sort_order" do
      tasks = [
        task(1, priority: "low"),
        task(2, priority: "high"),
        task(3, priority: "normal")
      ]

      result = Sort.apply(tasks, "priority")

      assert Enum.map(result, & &1.priority) == ["high", "normal", "low"]
      assert Enum.map(result, & &1.sort_order) == [@gap, 2 * @gap, 3 * @gap]
    end

    test "id tiebreaker for matching priority — lower id first regardless of input order" do
      a = task(100, priority: "high")
      b = task(1, priority: "high")
      c = task(50, priority: "high")

      for input <- [[a, b, c], [c, a, b], [b, c, a]] do
        assert Sort.apply(input, "priority") |> Enum.map(& &1.id) == [1, 50, 100]
      end
    end
  end

  describe "apply/3 — created" do
    test "orders inserted_at ascending (oldest first) and stamps sort_order" do
      base = DateTime.utc_now()

      tasks = [
        task(1, inserted_at: DateTime.add(base, 30, :second)),
        task(2, inserted_at: DateTime.add(base, 10, :second)),
        task(3, inserted_at: DateTime.add(base, 20, :second))
      ]

      result = Sort.apply(tasks, "created")

      assert Enum.map(result, & &1.id) == [2, 3, 1]
      assert Enum.map(result, & &1.sort_order) == [@gap, 2 * @gap, 3 * @gap]
    end

    test "id tiebreaker for identical inserted_at — lower id first regardless of input order" do
      base = DateTime.utc_now()
      a = task(40, inserted_at: base)
      b = task(10, inserted_at: base)
      c = task(25, inserted_at: base)

      for input <- [[a, b, c], [c, a, b], [b, c, a]] do
        assert Sort.apply(input, "created") |> Enum.map(& &1.id) == [10, 25, 40]
      end
    end
  end

  describe "apply/3 — updated" do
    test "orders updated_at descending (most recent first) and stamps sort_order" do
      base = DateTime.utc_now()

      tasks = [
        task(1, updated_at: DateTime.add(base, 10, :second)),
        task(2, updated_at: DateTime.add(base, 30, :second)),
        task(3, updated_at: DateTime.add(base, 20, :second))
      ]

      result = Sort.apply(tasks, "updated")

      assert Enum.map(result, & &1.id) == [2, 3, 1]
      assert Enum.map(result, & &1.sort_order) == [@gap, 2 * @gap, 3 * @gap]
    end

    test "id tiebreaker for identical updated_at — lower id first regardless of input order" do
      base = DateTime.utc_now()
      a = task(99, updated_at: base)
      b = task(11, updated_at: base)
      c = task(55, updated_at: base)

      for input <- [[a, b, c], [c, a, b], [b, c, a]] do
        assert Sort.apply(input, "updated") |> Enum.map(& &1.id) == [11, 55, 99]
      end
    end
  end

  describe "apply/3 — reverse?" do
    test "flips alphabetical to Z→A" do
      tasks = [task(1, title: "banana"), task(2, title: "Apple"), task(3, title: "cherry")]
      result = Sort.apply(tasks, "alphabetical", true)
      assert Enum.map(result, & &1.title) == ["cherry", "banana", "Apple"]
    end

    test "flips completion to done → in_progress → open" do
      tasks = [task(1, status: "open"), task(2, status: "done"), task(3, status: "in_progress")]
      result = Sort.apply(tasks, "completion", true)
      assert Enum.map(result, & &1.status) == ["done", "in_progress", "open"]
    end

    test "flips computed_progress to ascending (least progress first)" do
      tasks = [
        task(1, computed_progress: 25),
        task(2, computed_progress: 100),
        task(3, computed_progress: 0)
      ]

      result = Sort.apply(tasks, "computed_progress", true)
      assert Enum.map(result, & &1.computed_progress) == [0, 25, 100]
    end

    test "flips priority to low → normal → high" do
      tasks = [task(1, priority: "high"), task(2, priority: "low"), task(3, priority: "normal")]
      result = Sort.apply(tasks, "priority", true)
      assert Enum.map(result, & &1.priority) == ["low", "normal", "high"]
    end

    test "flips created to newest first" do
      base = DateTime.utc_now()

      tasks = [
        task(1, inserted_at: DateTime.add(base, 30, :second)),
        task(2, inserted_at: DateTime.add(base, 10, :second)),
        task(3, inserted_at: DateTime.add(base, 20, :second))
      ]

      result = Sort.apply(tasks, "created", true)
      assert Enum.map(result, & &1.id) == [1, 3, 2]
    end

    test "flips updated to oldest first" do
      base = DateTime.utc_now()

      tasks = [
        task(1, updated_at: DateTime.add(base, 10, :second)),
        task(2, updated_at: DateTime.add(base, 30, :second)),
        task(3, updated_at: DateTime.add(base, 20, :second))
      ]

      result = Sort.apply(tasks, "updated", true)
      assert Enum.map(result, & &1.id) == [1, 3, 2]
    end

    test "id tiebreaker stays ascending even when reversed" do
      a = task(10, title: "same")
      b = task(5, title: "same")
      c = task(7, title: "same")
      result = Sort.apply([a, b, c], "alphabetical", true)
      assert Enum.map(result, & &1.id) == [5, 7, 10]
    end

    test "still stamps sort_order with index*gap regardless of direction" do
      tasks = [task(1, title: "b"), task(2, title: "a"), task(3, title: "c")]
      result = Sort.apply(tasks, "alphabetical", true)
      assert Enum.map(result, & &1.sort_order) == [@gap, 2 * @gap, 3 * @gap]
    end
  end
end
