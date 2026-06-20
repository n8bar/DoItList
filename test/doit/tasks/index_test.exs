defmodule DoIt.Tasks.IndexTest do
  @moduledoc """
  Pure tests for positional task-index formatting (m02.07 item 1.7). No DB —
  exercises `DoIt.Tasks.Index.label/2` against hand-built position chains.
  """
  use ExUnit.Case, async: true

  alias DoIt.Tasks.Index

  describe "styles/0, default_style/0, valid_style?/1" do
    test "the accepted set is exactly the five fixed styles, none the default" do
      assert Enum.sort(Index.styles()) ==
               Enum.sort(~w(none outline numerical roman alphabetical))

      assert Index.default_style() == "none"

      for s <- ~w(none outline numerical roman alphabetical) do
        assert Index.valid_style?(s)
      end

      refute Index.valid_style?("bogus")
      refute Index.valid_style?("Outline")
    end
  end

  describe "none / empty / invalid" do
    test "none style yields no label at any depth" do
      assert Index.label([0], "none") == ""
      assert Index.label([0, 1, 2], "none") == ""
    end

    test "nil style and empty positions yield no label" do
      assert Index.label([0, 1], nil) == ""
      assert Index.label([], "numerical") == ""
    end

    test "an unrecognized style yields no label" do
      assert Index.label([0, 1], "bogus") == ""
    end
  end

  describe "numerical" do
    test "one 1-based numeric segment per level" do
      assert Index.label([0], "numerical") == "1"
      assert Index.label([0, 0], "numerical") == "1.1"
      assert Index.label([0, 1, 2], "numerical") == "1.2.3"
      assert Index.label([2, 0, 9], "numerical") == "3.1.10"
    end
  end

  describe "roman" do
    test "uppercase roman at every level" do
      assert Index.label([0], "roman") == "I"
      assert Index.label([0, 1, 2], "roman") == "I.II.III"
      assert Index.label([3], "roman") == "IV"
      assert Index.label([8], "roman") == "IX"
    end
  end

  describe "alphabetical" do
    test "uppercase letters at every level, wrapping past Z" do
      assert Index.label([0], "alphabetical") == "A"
      assert Index.label([0, 1, 2], "alphabetical") == "A.B.C"
      assert Index.label([25], "alphabetical") == "Z"
      assert Index.label([26], "alphabetical") == "AA"
      assert Index.label([27], "alphabetical") == "AB"
    end
  end

  describe "outline (I.A.1.a.i)" do
    test "alternates roman / alpha / numeric / alpha-lower / roman-lower by depth" do
      assert Index.label([0], "outline") == "I"
      assert Index.label([0, 0], "outline") == "I.A"
      assert Index.label([0, 0, 0], "outline") == "I.A.1"
      assert Index.label([0, 0, 0, 0], "outline") == "I.A.1.a"
      assert Index.label([0, 0, 0, 0, 0], "outline") == "I.A.1.a.i"
    end

    test "outline cycles back to roman at the sixth level" do
      assert Index.label([0, 0, 0, 0, 0, 0], "outline") == "I.A.1.a.i.I"
    end

    test "outline tracks sibling positions, not just first slots" do
      assert Index.label([2, 1, 3], "outline") == "III.B.4"
    end
  end

  describe "recompute on reorder is positional" do
    test "the same node yields a different label after its position changes" do
      # node was the 2nd child of the 1st list...
      assert Index.label([0, 1], "numerical") == "1.2"
      # ...drag it to be the 1st child of the 3rd list — label follows position.
      assert Index.label([2, 0], "numerical") == "3.1"
    end
  end
end
