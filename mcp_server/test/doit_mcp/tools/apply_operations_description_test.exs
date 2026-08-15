defmodule DoitMcp.Tools.ApplyOperationsDescriptionTest do
  use ExUnit.Case, async: true

  alias DoitMcp.ImportGate

  # m03.04 item 31 (reswept by item 36.3): the tool words state the import
  # classifier's numbers upfront and carry the no-stop model — readback as
  # record, never a confirm. Each bound is asserted through ImportGate's own
  # exposed functions, so a retune that forgets the tool words fails here
  # instead of drifting.
  describe "published tool description" do
    setup do
      # Collapsed whitespace so assertions survive the moduledoc's line wraps.
      description =
        DoitMcp.Tools.ApplyOperations.__description__()
        |> String.replace(~r/\s+/, " ")

      %{description: description}
    end

    test "names the ramp from the classifier's exposed bounds", %{description: description} do
      assert description =~ "up to #{ImportGate.threshold()} task-adds"
      assert description =~ "stretches to #{ImportGate.ramp_threshold()} while"
      assert description =~ "at most #{ImportGate.threshold()} adds"
    end

    test "carries the no-stop model, not the confirm contract (m03.04 item 36.3)", %{
      description: description
    } do
      assert description =~ "never stops an import"
      assert description =~ "provenance comment on the target Initiative's root task"
      assert description =~ "`operator_confirmed: true`"
      assert description =~ "Operator-confirmed in chat"
      refute description =~ "fresh floor"
      refute description =~ "confirm_url"
      refute description =~ "confirmation_pending"
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
