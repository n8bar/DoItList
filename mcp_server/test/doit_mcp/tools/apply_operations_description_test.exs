defmodule DoitMcp.Tools.ApplyOperationsDescriptionTest do
  use ExUnit.Case, async: true

  alias DoitMcp.ImportGate

  # m03.04 item 31: the tool words state the gate's numbers upfront. Each
  # bound is asserted through ImportGate's own exposed functions, so a
  # retune that forgets the tool words fails here instead of drifting.
  describe "published tool description" do
    setup do
      # Collapsed whitespace so assertions survive the moduledoc's line wraps.
      description =
        DoitMcp.Tools.ApplyOperations.__description__()
        |> String.replace(~r/\s+/, " ")

      %{description: description}
    end

    test "names the ramp from the gate's exposed bounds", %{description: description} do
      assert description =~ "up to #{ImportGate.threshold()} task-adds"
      assert description =~ "stretches to #{ImportGate.ramp_threshold()} while"
      assert description =~ "at most #{ImportGate.threshold()} adds"
    end

    test "names the fresh floor from the gate's exposed bound", %{description: description} do
      assert description =~ "past #{ImportGate.fresh_threshold()} cumulative task-adds"
    end

    test "names the description cap and its overflow doctrine", %{description: description} do
      # The cap is the app's (lib/doit/tasks/task.ex — validate_length
      # :description, max: 8000, both changesets), out of this suite's
      # reach, so the literal is pinned here beside its keep-in-sync note.
      assert description =~ "8000 characters"
      assert description =~ "continuation tasks"
    end

    test "states the ideal import shape", %{description: description} do
      assert description =~ "skeleton first"
      assert description =~ "provenance comment"
    end
  end
end
