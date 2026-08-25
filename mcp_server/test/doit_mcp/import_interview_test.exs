defmodule DoitMcp.ImportInterviewTest do
  @moduledoc """
  The first-import interview's pure core (m03.04 2.8.10): scope detection,
  declaration parsing/validation, and the cumulative arithmetic — refusal-
  precise (a chunk that could still be consistent never refuses; refusals
  name both numbers), with the declared-exclusion-of-completed lane routed
  to the caller's park.
  """
  use ExUnit.Case, async: true

  alias DoitMcp.{BatchShape, ImportInterview}

  @floor BatchShape.import_floor()

  defp decl(total, completed, excluded \\ 0) do
    %{total: total, completed: completed, excluded: excluded, exclusions: nil, ordering: "none"}
  end

  describe "first_import?/2" do
    test "fires on a small live tree at cumulative floor; fail-open on unknown" do
      assert ImportInterview.first_import?(0, @floor)
      assert ImportInterview.first_import?(@floor - 1, @floor + 5)
      refute ImportInterview.first_import?(@floor, @floor)
      refute ImportInterview.first_import?(0, @floor - 1)
      refute ImportInterview.first_import?(nil, 100)
    end
  end

  describe "from_params/1" do
    test "no declaration fields is :none" do
      assert ImportInterview.from_params(%{operations: []}) == :none
    end

    test "a whole-import declaration parses with zero exclusions" do
      params = %{
        declared_sources: [%{"path" => "PLAN.md", "checkbox_lines" => 20}],
        declared_total: 20,
        declared_completed: 5,
        declared_ordering: "outline"
      }

      assert {:ok, decl} = ImportInterview.from_params(params)
      assert decl.total == 20
      assert decl.completed == 5
      assert decl.excluded == 0
      assert decl.exclusions == []
      assert decl.ordering == "outline"
    end

    test "the flattening case: 340 checkbox lines declared, 12 items claimed (m03.04 2.8.11)" do
      # Initiative 72, 2026-08-25: the agent declared 12 items and created 12
      # tasks. Self-consistent, so 2.8.10's arithmetic passed. The source's
      # checkbox lines are the statement the plan can't quietly agree with.
      params = %{
        declared_sources: [
          %{"path" => "docs/PLAN.md", "checkbox_lines" => 40},
          %{"path" => "docs/milestones/M1.md", "checkbox_lines" => 300}
        ],
        declared_total: 12,
        declared_completed: 9,
        declared_ordering: "outline"
      }

      assert {:invalid, message} = ImportInterview.from_params(params)
      assert message =~ "340 checkbox lines across 2 file(s)"
      assert message =~ "only 12 items"
      assert message =~ "nested as the source nests them"
      # The cheap way out is declared, not re-derived.
      assert message =~ "`declared_exclusions`"
    end

    test "a source with no checkboxes can't accuse anyone" do
      params = %{
        declared_sources: [%{"path" => "notes.md", "checkbox_lines" => 0}],
        declared_total: 12,
        declared_completed: 0,
        declared_ordering: "none"
      }

      assert {:ok, decl} = ImportInterview.from_params(params)
      assert decl.total == 12
    end

    test "a total within the floor of the checkbox count flows — headings are real" do
      params = %{
        declared_sources: [%{"path" => "PLAN.md", "checkbox_lines" => 100}],
        declared_total: 60,
        declared_completed: 0,
        declared_ordering: "numerical"
      }

      assert {:ok, _decl} = ImportInterview.from_params(params)
    end

    test "declared_sources must be read off files, and says so when malformed" do
      base = %{declared_total: 10, declared_completed: 0, declared_ordering: "none"}

      assert {:invalid, missing} = ImportInterview.from_params(base)
      assert missing =~ "`declared_sources` must list every source document"

      assert {:invalid, bad} =
               ImportInterview.from_params(
                 Map.put(base, :declared_sources, [%{"path" => "PLAN.md"}])
               )

      assert bad =~ "not from your import plan"
    end

    test "exclusions sum and keep their verbatim reasons" do
      params = %{
        declared_sources: [%{"path" => "PLAN.md", "checkbox_lines" => 20}],
        declared_total: 20,
        declared_completed: 5,
        declared_exclusions: [
          %{"count" => 3, "reason" => "appendix notes — not tasks"},
          %{"count" => 2, "reason" => "duplicates of M1 items"}
        ],
        declared_ordering: "numerical"
      }

      assert {:ok, decl} = ImportInterview.from_params(params)
      assert decl.excluded == 5
      assert Enum.map(decl.exclusions, & &1.reason) |> Enum.at(0) =~ "appendix notes"
    end

    test "each invalid shape refuses naming the field" do
      base = %{
        declared_sources: [%{"path" => "PLAN.md", "checkbox_lines" => 10}],
        declared_total: 10,
        declared_completed: 0,
        declared_ordering: "none"
      }

      cases = [
        {%{base | declared_total: 0}, "`declared_total`"},
        {%{base | declared_completed: 11}, "`declared_completed` (11)"},
        {Map.put(base, :declared_exclusions, [%{"count" => 2, "reason" => "  "}]),
         "`declared_exclusions`"},
        {Map.put(base, :declared_exclusions, [%{"count" => 11, "reason" => "too many"}]),
         "declared exclusions (11) cannot exceed `declared_total` (10)"},
        {%{base | declared_ordering: " "}, "`declared_ordering`"},
        {Map.delete(base, :declared_ordering), "`declared_ordering`"}
      ]

      for {params, needle} <- cases do
        assert {:invalid, message} = ImportInterview.from_params(params)
        assert message =~ "Import declaration invalid — nothing was applied."
        assert message =~ needle
      end
    end
  end

  describe "check/3 — the cumulative arithmetic" do
    test "a consistent fresh plan flows — declared 0 complete, 0 done adds" do
      assert ImportInterview.check(decl(20, 0), 20, 0) == :ok
    end

    test "a whole import with matching done arrivals flows" do
      assert ImportInterview.check(decl(20, 5), 20, 5) == :ok
    end

    test "a partial chunk that could still be consistent never refuses" do
      # 8 of 20 delivered, 2 of 5 done so far — more may come.
      assert ImportInterview.check(decl(20, 5), 8, 2) == :ok
    end

    test "cumulative adds past the importable total refuse naming both numbers" do
      assert {:refuse, message} = ImportInterview.check(decl(20, 0, 5), 16, 0)
      assert message =~ "Import declaration mismatch — nothing was applied."
      assert message =~ "cumulative adds reach 16"
      assert message =~ "importable total of 15"
      assert message =~ "20 declared minus 5 excluded"
    end

    test "done arrivals past the declared completed count refuse naming both numbers" do
      assert {:refuse, message} = ImportInterview.check(decl(20, 2), 10, 3)
      assert message =~ "3 tasks arrive `done` against 2 declared complete"
    end

    test "an import completing short of its completed count with no exclusions to absorb it refuses" do
      assert {:refuse, message} = ImportInterview.check(decl(20, 5), 20, 0)
      assert message =~ "complete at 20 adds with 0 arrived `done`"
      assert message =~ "0 declared exclusions cannot absorb the 5 missing completed items"
      assert message =~ "`done: true`"
    end

    test "an import completing with declared-complete work inside the exclusions parks" do
      assert ImportInterview.check(decl(20, 5, 5), 15, 0) == :excluded_completed
      # Partial absorption counts too: 2 done arrived, 3 missing, 3+ excluded.
      assert ImportInterview.check(decl(20, 5, 3), 17, 2) == :excluded_completed
    end
  end

  describe "messages and blocks" do
    test "the demand teaches the four fields and the chunk contract" do
      message = ImportInterview.demand_message(12, false)

      assert message =~ "First-import declaration required"
      assert message =~ "12 task-adds"
      assert message =~ "Nothing was applied; no operator step is needed."
      assert message =~ "`declared_total`"
      assert message =~ "`declared_completed`"
      assert message =~ "`declared_exclusions`"
      assert message =~ "`declared_ordering`"
      assert message =~ "every later chunk of this import is checked against the same declaration"
      refute message =~ "readback"

      assert ImportInterview.demand_message(40, true) =~ "carry `readback` too"
    end

    test "the parked message names both recoveries with no attestation vocabulary" do
      message = ImportInterview.parked_message(decl(20, 5, 5), 0)

      assert message =~ "Import parked — nothing was applied."
      assert message =~ "5 declared complete, 0 arriving `done`"
      assert message =~ "the operator's call"
      assert message =~ "`done: true` adds"
      assert message =~ "re-send this SAME batch unchanged"
      refute message =~ "operator_confirmed"
    end

    test "the declined message latches — change the batch or talk to the operator" do
      message = ImportInterview.declined_message()

      assert message =~ "operator rejected"
      assert message =~ "`done: true` adds"
      assert message =~ "talk to the operator"
      refute message =~ "operator_confirmed"
    end

    test "the declaration block renders the stated numbers and verbatim reasons" do
      {:ok, parsed} =
        ImportInterview.from_params(%{
          declared_sources: [%{"path" => "PLAN.md", "checkbox_lines" => 20}],
          declared_total: 20,
          declared_completed: 5,
          declared_exclusions: [%{"count" => 2, "reason" => "appendix notes"}],
          declared_ordering: "outline"
        })

      block = ImportInterview.declaration_block(parsed)
      assert block =~ "Import declaration (agent-stated, server-checked):"
      assert block =~ "- Source: 20 items, 5 complete."
      assert block =~ "- Exclusions (2 items): 2 × appendix notes."
      assert block =~ "- Ordering: outline."

      assert ImportInterview.declaration_block(decl(9, 0)) =~ "- Exclusions: none declared."
    end

    test "record_attrs carries the wire body for the Initiative-homed record" do
      {:ok, parsed} =
        ImportInterview.from_params(%{
          declared_sources: [%{"path" => "PLAN.md", "checkbox_lines" => 20}],
          declared_total: 20,
          declared_completed: 5,
          declared_exclusions: [%{"count" => 2, "reason" => "appendix notes"}],
          declared_ordering: "outline"
        })

      assert ImportInterview.record_attrs(parsed, 57) == %{
               initiative_id: 57,
               source_total: 20,
               source_completed: 5,
               excluded_count: 2,
               exclusions: "2 × appendix notes",
               ordering: "outline"
             }
    end
  end

  describe "from_consult/1" do
    test "normalizes the server's declaration map; unreadable shapes are nil" do
      assert %{total: 20, completed: 5, excluded: 3, exclusions: nil, ordering: "outline"} =
               ImportInterview.from_consult(%{
                 "source_total" => 20,
                 "source_completed" => 5,
                 "excluded_count" => 3,
                 "ordering" => "outline"
               })

      assert ImportInterview.from_consult(nil) == nil
      assert ImportInterview.from_consult(%{"source_total" => "20"}) == nil
    end
  end
end
