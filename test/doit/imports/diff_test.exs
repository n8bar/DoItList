defmodule DoIt.Imports.DiffTest do
  @moduledoc """
  Pure tests for import diffing (m03.04 item 2.5). No DB — a manifest's items
  on one side, live-tree maps on the other, and the report they produce.
  """
  use ExUnit.Case, async: true

  alias DoIt.Imports.Diff

  # --- helpers ---------------------------------------------------------------

  # A source (manifest) item.
  defp src(title, opts \\ []) do
    %{
      title: title,
      description: nil,
      done: Keyword.get(opts, :done, false),
      children: Keyword.get(opts, :children, [])
    }
  end

  # A live item, carrying the task id findings echo back.
  defp live(title, opts) do
    %{
      id: Keyword.get(opts, :id),
      title: title,
      done: Keyword.get(opts, :done, false),
      children: Keyword.get(opts, :children, [])
    }
  end

  # --- 2.5.1 identical trees --------------------------------------------------

  describe "identical trees" do
    test "a matching tree is clean, with every item counted as matched" do
      source = [
        src("Ship the thing", children: [src("Draft the spec"), src("Book the room", done: true)]),
        src("Tell everyone")
      ]

      live = [
        live("Ship the thing",
          id: 1,
          children: [live("Draft the spec", id: 2), live("Book the room", id: 3, done: true)]
        ),
        live("Tell everyone", id: 4)
      ]

      report = Diff.compare(source, live)

      assert report["clean"] == true

      assert report["summary"] == %{
               "matched" => 4,
               "missing" => 0,
               "extra" => 0,
               "completion" => 0,
               "order" => 0
             }

      assert report["missing"] == []
      assert report["extra"] == []
      assert report["completion"] == []
      assert report["order"] == []
    end

    test "two empty levels are clean" do
      assert Diff.compare([], [])["clean"] == true
    end

    test "surrounding whitespace does not break a match" do
      assert Diff.compare([src("  Ship it  ")], [live("Ship it", id: 1)])["clean"] == true
    end
  end

  # --- 2.5.2 the four finding kinds -------------------------------------------

  describe "missing" do
    test "a source item with no live counterpart is reported with its path" do
      source = [src("Ship the thing", children: [src("Draft the spec"), src("Book the room")])]
      live = [live("Ship the thing", id: 1, children: [live("Book the room", id: 3)])]

      report = Diff.compare(source, live)

      refute report["clean"]
      assert report["summary"]["missing"] == 1

      assert report["missing"] == [
               %{"path" => "Ship the thing > Draft the spec", "title" => "Draft the spec"}
             ]

      assert report["extra"] == []
    end

    test "a top-level missing item's path is just its title" do
      assert Diff.compare([src("Tell everyone")], [])["missing"] == [
               %{"path" => "Tell everyone", "title" => "Tell everyone"}
             ]
    end
  end

  describe "extra" do
    test "a live item the document doesn't have is reported with its id" do
      report = Diff.compare([src("Ship the thing")], [live("Surprise chore", id: 9)])

      assert report["summary"] == %{
               "matched" => 0,
               "missing" => 1,
               "extra" => 1,
               "completion" => 0,
               "order" => 0
             }

      assert report["extra"] == [
               %{"path" => "Surprise chore", "title" => "Surprise chore", "id" => 9}
             ]
    end

    test "an extra branch is one finding — its children are not enumerated" do
      live = [
        live("Ship the thing", id: 1),
        live("Side quest",
          id: 5,
          children: [live("Step one", id: 6, children: [live("Step one a", id: 7)])]
        )
      ]

      report = Diff.compare([src("Ship the thing")], live)

      assert report["extra"] == [
               %{"path" => "Side quest", "title" => "Side quest", "id" => 5}
             ]

      # The branch itself is the finding: nothing under it is walked.
      assert report["summary"]["extra"] == 1
      assert report["summary"]["matched"] == 1
    end

    test "a missing branch is one finding too" do
      source = [src("Big branch", children: [src("Under it", children: [src("Deeper")])])]

      report = Diff.compare(source, [])

      assert report["missing"] == [%{"path" => "Big branch", "title" => "Big branch"}]
      assert report["summary"]["missing"] == 1
    end
  end

  describe "completion" do
    test "a matched pair whose done differs is reported both ways" do
      source = [src("Draft the spec", done: true), src("Book the room")]
      live = [live("Draft the spec", id: 2), live("Book the room", id: 3, done: true)]

      report = Diff.compare(source, live)

      assert report["summary"]["completion"] == 2
      assert report["missing"] == []
      assert report["extra"] == []

      assert report["completion"] == [
               %{
                 "path" => "Draft the spec",
                 "source_done" => true,
                 "live_done" => false,
                 "id" => 2
               },
               %{
                 "path" => "Book the room",
                 "source_done" => false,
                 "live_done" => true,
                 "id" => 3
               }
             ]
    end
  end

  describe "order" do
    test "reordered siblings make one entry naming the parent and both orderings" do
      source = [src("First"), src("Second"), src("Third")]
      live = [live("Third", id: 3), live("First", id: 1), live("Second", id: 2)]

      report = Diff.compare(source, live)

      assert report["summary"]["order"] == 1
      assert report["missing"] == []
      assert report["extra"] == []

      assert report["order"] == [
               %{
                 "parent" => "(root)",
                 "source" => ["First", "Second", "Third"],
                 "live" => ["Third", "First", "Second"]
               }
             ]
    end

    test "an interleaved extra item does not by itself make an order mismatch" do
      source = [src("First"), src("Second")]
      live = [live("First", id: 1), live("Interloper", id: 9), live("Second", id: 2)]

      report = Diff.compare(source, live)

      assert report["order"] == []
      assert report["summary"]["extra"] == 1
    end

    test "a nested reorder names its parent by path" do
      source = [src("Ship the thing", children: [src("Draft"), src("Book")])]

      live = [
        live("Ship the thing", id: 1, children: [live("Book", id: 3), live("Draft", id: 2)])
      ]

      assert Diff.compare(source, live)["order"] == [
               %{
                 "parent" => "Ship the thing",
                 "source" => ["Draft", "Book"],
                 "live" => ["Book", "Draft"]
               }
             ]
    end
  end

  # --- nesting, duplicates, case ----------------------------------------------

  describe "nested findings" do
    test "findings under a matched branch carry the branch in their paths" do
      source = [
        src("Ship the thing",
          children: [
            src("Draft the spec", children: [src("Outline"), src("Review", done: true)])
          ]
        )
      ]

      live = [
        live("Ship the thing",
          id: 1,
          children: [
            live("Draft the spec",
              id: 2,
              children: [live("Review", id: 4), live("Stray note", id: 5)]
            )
          ]
        )
      ]

      report = Diff.compare(source, live)

      assert report["missing"] == [
               %{
                 "path" => "Ship the thing > Draft the spec > Outline",
                 "title" => "Outline"
               }
             ]

      assert report["extra"] == [
               %{
                 "path" => "Ship the thing > Draft the spec > Stray note",
                 "title" => "Stray note",
                 "id" => 5
               }
             ]

      assert report["completion"] == [
               %{
                 "path" => "Ship the thing > Draft the spec > Review",
                 "source_done" => true,
                 "live_done" => false,
                 "id" => 4
               }
             ]

      assert report["summary"]["matched"] == 3
    end
  end

  describe "duplicate titles" do
    test "siblings sharing a title pair in order, k-th to k-th" do
      source = [
        src("Follow up", children: [src("Ping")]),
        src("Follow up", children: [src("Call")])
      ]

      live = [
        live("Follow up", id: 1, children: [live("Ping", id: 2)]),
        live("Follow up", id: 3, children: [live("Call", id: 4)])
      ]

      assert Diff.compare(source, live)["clean"] == true
    end

    test "an unequal number of same-titled siblings reports only the surplus" do
      source = [src("Follow up"), src("Follow up"), src("Follow up")]
      live = [live("Follow up", id: 1), live("Follow up", id: 2)]

      report = Diff.compare(source, live)

      assert report["summary"]["matched"] == 2
      assert report["missing"] == [%{"path" => "Follow up", "title" => "Follow up"}]
      assert report["extra"] == []
    end
  end

  describe "case-insensitive matching" do
    test "a case-only difference matches rather than reporting missing and extra" do
      report = Diff.compare([src("SHIP THE THING")], [live("Ship the thing", id: 1)])

      assert report["clean"] == true
      assert report["summary"]["matched"] == 1
    end

    test "an exact title wins the slot over a case-only near-match" do
      source = [src("Ship"), src("SHIP")]
      live = [live("SHIP", id: 1), live("Ship", id: 2)]

      report = Diff.compare(source, live)

      # "Ship" takes live id 2 exactly, leaving "SHIP" the loose match on id 1
      # — so the live order of the matched pair is reversed, and that is the
      # only finding.
      assert report["summary"]["matched"] == 2
      assert report["missing"] == []
      assert report["extra"] == []
      assert [%{"parent" => "(root)", "source" => ["Ship", "SHIP"]}] = report["order"]
    end
  end

  describe "live items without ids" do
    test "findings carry a null id rather than failing" do
      report = Diff.compare([], [%{title: "Loose", done: false, children: []}])

      assert report["extra"] == [%{"path" => "Loose", "title" => "Loose", "id" => nil}]
    end
  end
end
