defmodule DoitMcp.ImportGateTest do
  # Not async: the kill-switch tests mutate the global process environment.
  use ExUnit.Case, async: false

  alias DoitMcp.ImportGate

  @threshold ImportGate.threshold()

  # The gate ships dark (DOITLIST_IMPORT_GATE=on arms it); arm it here so the
  # decision tests exercise the armed path. The "kill switch" describe drops
  # this override to test the env-var semantics themselves.
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  # Effectful inputs that must NOT be reached prove short-circuit order.
  defp never_elicitation, do: fn -> flunk("capability check must not run") end
  defp never_fetch, do: fn _id -> flunk("initiative fetch must not run") end

  defp yes_elicitation, do: fn -> true end
  defp no_elicitation, do: fn -> false end

  defp task_adds(count, data) do
    for i <- 1..count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => Map.put(data, "title", "task #{i}")
      }
    end
  end

  defp new_initiative_batch(count) do
    [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
      task_adds(count, %{"initiative_lid" => "i"})
  end

  describe "evaluate/2 kill switch (condition 0)" do
    test "unset (the default) passes even a batch everything else would gate, counting nothing" do
      Application.delete_env(:doit_mcp, :import_gate_enabled)
      System.delete_env("DOITLIST_IMPORT_GATE")

      refute ImportGate.enabled?()

      assert ImportGate.evaluate(new_initiative_batch(@threshold + 1),
               elicitation?: never_elicitation(),
               fetch_initiative: never_fetch()
             ) == :pass
    end

    test "DOITLIST_IMPORT_GATE=on arms the gate; any other value leaves it off" do
      Application.delete_env(:doit_mcp, :import_gate_enabled)
      System.put_env("DOITLIST_IMPORT_GATE", "on")
      on_exit(fn -> System.delete_env("DOITLIST_IMPORT_GATE") end)

      assert ImportGate.enabled?()

      assert {:gate, %{target: {:in_batch, "i"}}} =
               ImportGate.evaluate(new_initiative_batch(@threshold + 1),
                 elicitation?: yes_elicitation(),
                 fetch_initiative: never_fetch()
               )

      System.put_env("DOITLIST_IMPORT_GATE", "off")

      assert ImportGate.evaluate(new_initiative_batch(@threshold + 1),
               elicitation?: never_elicitation(),
               fetch_initiative: never_fetch()
             ) == :pass
    end
  end

  describe "evaluate/2 threshold (condition 1)" do
    test "exactly the threshold of task-adds passes without touching capability or fetch" do
      ops = new_initiative_batch(@threshold)

      assert ImportGate.evaluate(ops,
               elicitation?: never_elicitation(),
               fetch_initiative: never_fetch()
             ) == :pass
    end

    test "non-task and non-add ops don't count toward the threshold" do
      ops =
        new_initiative_batch(@threshold - 1) ++
          [
            %{"op" => "update", "type" => "task", "lid" => "t1", "data" => %{"done" => true}},
            %{"op" => "add", "type" => "comment", "data" => %{"task_lid" => "t1", "body" => "hi"}}
          ]

      assert ImportGate.count_task_adds(ops) == @threshold - 1

      assert ImportGate.evaluate(ops,
               elicitation?: never_elicitation(),
               fetch_initiative: never_fetch()
             ) == :pass
    end
  end

  describe "evaluate/2 capability (condition 2)" do
    test "over threshold but no elicitation capability passes without fetching" do
      ops = new_initiative_batch(@threshold + 1)

      assert ImportGate.evaluate(ops,
               elicitation?: no_elicitation(),
               fetch_initiative: never_fetch()
             ) == :pass
    end
  end

  describe "evaluate/2 target knobs (condition 3)" do
    test "an initiative created in the same batch is knob-less by definition — gated, no fetch" do
      ops = new_initiative_batch(@threshold + 1)

      assert {:gate, %{task_adds: task_adds, target: {:in_batch, "i"}}} =
               ImportGate.evaluate(ops,
                 elicitation?: yes_elicitation(),
                 fetch_initiative: never_fetch()
               )

      assert task_adds == @threshold + 1
    end

    test "an existing target with empty ai_knobs gates, fetched exactly once" do
      ops = task_adds(@threshold + 1, %{"initiative_id" => 7})
      parent = self()

      fetch = fn id ->
        send(parent, {:fetched, id})
        {:ok, %{"id" => id, "ai_knobs" => nil}}
      end

      assert {:gate, %{target: {:existing, 7}}} =
               ImportGate.evaluate(ops, elicitation?: yes_elicitation(), fetch_initiative: fetch)

      assert_received {:fetched, 7}
      refute_received {:fetched, _}
    end

    test "whitespace-only ai_knobs counts as empty" do
      ops = task_adds(@threshold + 1, %{"initiative_id" => 7})
      fetch = fn _id -> {:ok, %{"ai_knobs" => "  \n"}} end

      assert {:gate, _} =
               ImportGate.evaluate(ops, elicitation?: yes_elicitation(), fetch_initiative: fetch)
    end

    test "settled ai_knobs passes" do
      ops = task_adds(@threshold + 1, %{"initiative_id" => 7})
      fetch = fn _id -> {:ok, %{"ai_knobs" => "deploy_day: friday"}} end

      assert ImportGate.evaluate(ops, elicitation?: yes_elicitation(), fetch_initiative: fetch) ==
               :pass
    end

    test "a fetch error passes — the apply surfaces the real error" do
      ops = task_adds(@threshold + 1, %{"initiative_id" => 404})
      fetch = fn _id -> {:error, %{status: 404}} end

      assert ImportGate.evaluate(ops, elicitation?: yes_elicitation(), fetch_initiative: fetch) ==
               :pass
    end

    test "adds hanging off an existing task (parent_id only) have no resolvable target — pass" do
      ops = task_adds(@threshold + 1, %{"parent_id" => 42})

      assert ImportGate.target_refs(ops) == []

      assert ImportGate.evaluate(ops,
               elicitation?: yes_elicitation(),
               fetch_initiative: never_fetch()
             ) == :pass
    end
  end

  describe "target_refs/1 parent-chain resolution" do
    test "children inherit the initiative through in-batch parent_lid chains" do
      ops = [
        %{"op" => "add", "type" => "task", "lid" => "root", "data" => %{"initiative_id" => 9}},
        %{"op" => "add", "type" => "task", "lid" => "mid", "data" => %{"parent_lid" => "root"}},
        %{"op" => "add", "type" => "task", "lid" => "leaf", "data" => %{"parent_lid" => "mid"}}
      ]

      assert ImportGate.target_refs(ops) == [{:existing, 9}]
    end

    test "a dangling or cyclic parent_lid resolves to nothing instead of looping" do
      ops = [
        %{"op" => "add", "type" => "task", "lid" => "a", "data" => %{"parent_lid" => "b"}},
        %{"op" => "add", "type" => "task", "lid" => "b", "data" => %{"parent_lid" => "a"}},
        %{"op" => "add", "type" => "task", "lid" => "c", "data" => %{"parent_lid" => "ghost"}}
      ]

      assert ImportGate.target_refs(ops) == []
    end

    test "mixed refs dedupe in batch order" do
      ops =
        task_adds(2, %{"initiative_id" => 9}) ++
          [%{"op" => "add", "type" => "task", "lid" => "x", "data" => %{"initiative_lid" => "i"}}]

      assert ImportGate.target_refs(ops) == [{:existing, 9}, {:in_batch, "i"}]
    end
  end
end
