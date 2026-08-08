defmodule DoitMcp.ImportGateTest do
  # Not async: the kill-switch tests mutate the global process environment.
  use ExUnit.Case, async: false

  alias DoitMcp.ImportGate

  @threshold ImportGate.threshold()

  # The gate ships armed (DOITLIST_IMPORT_GATE=off opts out); pin it on here
  # so the decision tests stay deterministic against the container's ambient
  # environment. The "kill switch" describe drops this override to test the
  # env-var semantics themselves.
  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  # Effectful inputs that must NOT be reached prove short-circuit order.
  defp never_fresh, do: fn _target -> flunk("fresh? must not run") end

  # AI-KNOBS-PARKED (m03.04): the revived `:fetch_initiative` option is
  # required again, so revive re-threads `fetch_initiative:` (this fun / the
  # parked tests' stub fns) through every live evaluate call below.
  # defp never_fetch, do: fn _id -> flunk("initiative fetch must not run") end

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
    test "unset (the default) arms the gate" do
      Application.delete_env(:doit_mcp, :import_gate_enabled)
      System.delete_env("DOITLIST_IMPORT_GATE")

      assert ImportGate.enabled?()

      assert {:gate, %{target: {:in_batch, "i"}}} =
               ImportGate.evaluate(new_initiative_batch(@threshold + 1))
    end

    test "DOITLIST_IMPORT_GATE=off opts out, counting nothing; any other value stays armed" do
      Application.delete_env(:doit_mcp, :import_gate_enabled)
      System.put_env("DOITLIST_IMPORT_GATE", "off")
      on_exit(fn -> System.delete_env("DOITLIST_IMPORT_GATE") end)

      refute ImportGate.enabled?()

      assert ImportGate.evaluate(new_initiative_batch(@threshold + 1)) == :pass

      System.put_env("DOITLIST_IMPORT_GATE", "on")
      assert ImportGate.enabled?()

      assert {:gate, %{target: {:in_batch, "i"}}} =
               ImportGate.evaluate(new_initiative_batch(@threshold + 1))
    end
  end

  describe "evaluate/2 threshold (condition 1)" do
    # These run in the AGED lane (`:fresh?` omitted → its pure default,
    # false): an in-batch Initiative is fresh by definition and now meets
    # the fresh floor instead — that lane lives in its own describe below.
    test "exactly the threshold of task-adds passes" do
      # Mixed anchors (initiative_id + parent_id) keep the tight bound;
      # landing exactly ON it is no crossing.
      ops =
        task_adds(@threshold - 1, %{"initiative_id" => 7}) ++
          [
            %{
              "op" => "add",
              "type" => "task",
              "lid" => "p",
              "data" => %{"parent_id" => 42, "title" => "p"}
            }
          ]

      assert ImportGate.evaluate(ops,
               parent_targets: %{42 => {:existing, 7}}
             ) == :pass
    end

    test "non-task and non-add ops don't count toward the threshold" do
      ops =
        task_adds(@threshold - 1, %{"initiative_id" => 7}) ++
          [
            %{"op" => "update", "type" => "task", "lid" => "t1", "data" => %{"done" => true}},
            %{"op" => "add", "type" => "comment", "data" => %{"task_lid" => "t1", "body" => "hi"}}
          ]

      assert ImportGate.count_task_adds(ops) == @threshold - 1

      assert ImportGate.evaluate(ops) == :pass
    end
  end

  describe "evaluate/2 gated-target selection (condition 2)" do
    test "an over-threshold existing target gates — knobs parked, every unsettled target asks" do
      ops = task_adds(@threshold + 1, %{"initiative_id" => 7})

      assert {:gate, %{task_adds: task_adds, cumulative: total, target: {:existing, 7}}} =
               ImportGate.evaluate(ops)

      assert task_adds == @threshold + 1
      assert total == @threshold + 1
    end

    test "an in-batch initiative is unsettled by definition and wins the pick over an earlier existing candidate" do
      # Both targets cross the tight bound; the in-batch one gates even though
      # the existing one comes first in batch order.
      existing = task_adds(@threshold + 1, %{"initiative_id" => 7})

      in_batch =
        [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
          for i <- 1..(@threshold + 1) do
            %{
              "op" => "add",
              "type" => "task",
              "lid" => "n#{i}",
              "data" => %{"initiative_lid" => "i", "title" => "new #{i}"}
            }
          end

      assert {:gate, %{task_adds: task_adds, target: {:in_batch, "i"}}} =
               ImportGate.evaluate(existing ++ in_batch)

      assert task_adds == @threshold + 1
    end

    # AI-KNOBS-PARKED (m03.04): the knobs exemption's decision lanes — settled
    # ai_knobs passed, empty/whitespace knobs gated (fetched exactly once),
    # and a fetch error passed (the apply surfaces the real error). Revive
    # with knobless_target/2 and the `:fetch_initiative` option, plus
    # never_fetch/0 at the top of this file.
    #
    # test "an existing target with empty ai_knobs gates, fetched exactly once" do
    #   ops = task_adds(@threshold + 1, %{"initiative_id" => 7})
    #   parent = self()
    #
    #   fetch = fn id ->
    #     send(parent, {:fetched, id})
    #     {:ok, %{"id" => id, "ai_knobs" => nil}}
    #   end
    #
    #   assert {:gate, %{target: {:existing, 7}}} =
    #            ImportGate.evaluate(ops, fetch_initiative: fetch)
    #
    #   assert_received {:fetched, 7}
    #   refute_received {:fetched, _}
    # end
    #
    # test "whitespace-only ai_knobs counts as empty" do
    #   ops = task_adds(@threshold + 1, %{"initiative_id" => 7})
    #   fetch = fn _id -> {:ok, %{"ai_knobs" => "  \n"}} end
    #
    #   assert {:gate, _} =
    #            ImportGate.evaluate(ops, fetch_initiative: fetch)
    # end
    #
    # test "settled ai_knobs passes" do
    #   ops = task_adds(@threshold + 1, %{"initiative_id" => 7})
    #   fetch = fn _id -> {:ok, %{"ai_knobs" => "deploy_day: friday"}} end
    #
    #   assert ImportGate.evaluate(ops, fetch_initiative: fetch) ==
    #            :pass
    # end
    #
    # test "a fetch error passes — the apply surfaces the real error" do
    #   ops = task_adds(@threshold + 1, %{"initiative_id" => 404})
    #   fetch = fn _id -> {:error, %{status: 404}} end
    #
    #   assert ImportGate.evaluate(ops, fetch_initiative: fetch) ==
    #            :pass
    # end

    test "adds hanging off an existing task (parent_id only) have no resolvable target — pass" do
      ops = task_adds(@threshold + 1, %{"parent_id" => 42})

      assert ImportGate.target_refs(ops) == []

      assert ImportGate.evaluate(ops) == :pass
    end
  end

  describe "evaluate/2 cumulative trigger (m03.03 item 5.11.2)" do
    test "a sub-threshold batch gates once the session counter pushes its target over the line" do
      # A coherent unit rides the ramp, so the crossing here is the RAMP bound.
      ops = task_adds(10, %{"initiative_id" => 7})
      expected_total = ImportGate.ramp_threshold() + 7

      assert {:gate, %{task_adds: 10, cumulative: ^expected_total, target: {:existing, 7}}} =
               ImportGate.evaluate(ops,
                 cumulative: fn {:existing, 7} -> ImportGate.ramp_threshold() - 3 end
               )
    end

    test "landing exactly ON the bound passes — the gate needs a crossing" do
      ops = task_adds(10, %{"initiative_id" => 7})

      assert ImportGate.evaluate(ops,
               cumulative: fn _ -> ImportGate.ramp_threshold() - 10 end
             ) == :pass
    end

    test "counts are per Initiative — only the crossing target gates" do
      ops =
        task_adds(5, %{"initiative_id" => 7}) ++
          for i <- 1..5 do
            %{
              "op" => "add",
              "type" => "task",
              "lid" => "other#{i}",
              "data" => %{"initiative_id" => 8, "title" => "task #{i}"}
            }
          end

      history = fn
        {:existing, 8} -> @threshold
        {:existing, 7} -> 0
      end

      expected_total = @threshold + 5

      assert {:gate, %{task_adds: 5, cumulative: ^expected_total, target: {:existing, 8}}} =
               ImportGate.evaluate(ops,
                 cumulative: history
               )
    end

    test "an operator-confirmed target never re-gates, even far over the line" do
      ops = task_adds(10, %{"initiative_id" => 7})

      assert ImportGate.evaluate(ops,
               cumulative: fn _ -> ImportGate.ramp_threshold() + 100 end,
               confirmed?: fn {:existing, 7} -> true end
             ) == :pass
    end
  end

  describe "the ramp (m03.04 3.1 iteration 2)" do
    test "a coherent one-list batch flows past the tight threshold" do
      # Well over 32 cumulative, but every add hangs under one parent and the
      # batch is capped — the ramp's whole point.
      ops = task_adds(10, %{"initiative_id" => 7})

      assert ImportGate.evaluate(ops,
               cumulative: fn _ -> @threshold + 20 end
             ) == :pass
    end

    test "mixed parents lose the ramp — the tight threshold gates" do
      ops =
        task_adds(5, %{"initiative_id" => 7}) ++
          for i <- 1..5 do
            %{
              "op" => "add",
              "type" => "task",
              "lid" => "p#{i}",
              "data" => %{"parent_id" => 42, "title" => "task #{i}"}
            }
          end

      assert {:gate, %{target: {:existing, 7}}} =
               ImportGate.evaluate(ops,
                 cumulative: fn _ -> @threshold end,
                 parent_targets: %{42 => {:existing, 7}}
               )
    end

    test "coherent_unit?: one subtree via parent_lid chains counts as one list" do
      ops = [
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "root",
          "data" => %{"initiative_id" => 7, "title" => "Worklist"}
        },
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "c1",
          "data" => %{"parent_lid" => "root", "title" => "a"}
        },
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "c2",
          "data" => %{"parent_lid" => "c1", "title" => "b"}
        }
      ]

      assert ImportGate.coherent_unit?(ops)
    end

    test "coherent_unit?: over the per-batch cap is not a unit" do
      refute ImportGate.coherent_unit?(task_adds(@threshold + 1, %{"initiative_id" => 7}))
    end

    test "coherent_unit?: a dangling parent_lid or anchorless add is not coherent" do
      dangling = [
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "x",
          "data" => %{"parent_lid" => "ghost", "title" => "a"}
        }
      ]

      anchorless = [%{"op" => "add", "type" => "task", "lid" => "y", "data" => %{"title" => "b"}}]

      refute ImportGate.coherent_unit?(dangling)
      refute ImportGate.coherent_unit?(anchorless)
    end
  end

  describe "the fresh floor (m03.04 3.1 iteration 3)" do
    test "a fresh in-batch Initiative gates past the floor — fresh? never consulted" do
      # 9 adds under one in-batch Initiative: coherent, under every old bound
      # — the pre-floor gate flowed this silently (the observed failure).
      ops = new_initiative_batch(9)

      assert {:gate, %{task_adds: 9, cumulative: 9, target: {:in_batch, "i"}, fresh: true}} =
               ImportGate.evaluate(ops,
                 fresh?: never_fresh()
               )
    end

    test "the floor is exclusive: a fresh Initiative's first #{ImportGate.fresh_threshold()} adds flow" do
      ops = new_initiative_batch(ImportGate.fresh_threshold())

      assert ImportGate.evaluate(ops,
               fresh?: never_fresh()
             ) == :pass
    end

    test "a fresh existing target gates in the band — the operator adjudicates the first import" do
      ops = task_adds(12, %{"initiative_id" => 7})

      assert {:gate, %{task_adds: 12, cumulative: 12, target: {:existing, 7}, fresh: true}} =
               ImportGate.evaluate(ops,
                 fresh?: fn {:existing, 7} -> true end
               )
    end

    test "an aged existing target keeps the old bounds — the same batch flows" do
      ops = task_adds(12, %{"initiative_id" => 7})

      assert ImportGate.evaluate(ops,
               fresh?: fn {:existing, 7} -> false end
             ) == :pass
    end

    test "the operator's confirm settles a fresh Initiative — later chunks flow" do
      ops = task_adds(12, %{"initiative_id" => 7})

      assert ImportGate.evaluate(ops,
               fresh?: fn {:existing, 7} -> true end,
               confirmed?: fn {:existing, 7} -> true end
             ) == :pass
    end

    test "cheapest-first: fresh? never runs below the floor nor for an over-bound target" do
      # Sub-floor: the floor can't matter, so no freshness IO.
      sub_floor = task_adds(ImportGate.fresh_threshold(), %{"initiative_id" => 7})

      assert ImportGate.evaluate(sub_floor,
               fresh?: never_fresh()
             ) == :pass

      # Over-bound: the target gates regardless — freshness is moot, no IO.
      over_bound = task_adds(@threshold + 1, %{"initiative_id" => 7})

      assert {:gate, %{target: {:existing, 7}, fresh: false}} =
               ImportGate.evaluate(over_bound,
                 fresh?: never_fresh()
               )
    end
  end

  describe "count_by_target/1" do
    test "sums task-adds per resolved Initiative in first-seen batch order" do
      ops =
        task_adds(2, %{"initiative_id" => 9}) ++
          [
            %{
              "op" => "add",
              "type" => "task",
              "lid" => "x",
              "data" => %{"initiative_lid" => "i"}
            },
            %{"op" => "add", "type" => "task", "lid" => "y", "data" => %{"initiative_id" => 9}},
            %{"op" => "add", "type" => "task", "lid" => "z", "data" => %{"parent_id" => 42}}
          ]

      assert ImportGate.count_by_target(ops) == [{{:existing, 9}, 3}, {{:in_batch, "i"}, 1}]
    end
  end

  describe "fresh-initiative rekey (m03.04 item 2.11.2)" do
    test "created_initiative_ids/2 maps only initiative-add lids from ok results" do
      ops = new_initiative_batch(2)

      results = [
        %{
          "index" => 0,
          "lid" => "i",
          "status" => "ok",
          "data" => %{"id" => 57, "type" => "initiative"}
        },
        %{
          "index" => 1,
          "lid" => "t1",
          "status" => "ok",
          "data" => %{"id" => 100, "type" => "task"}
        }
      ]

      assert ImportGate.created_initiative_ids(ops, results) == %{"i" => 57}
    end

    test "an unreadable results shape maps nothing" do
      ops = new_initiative_batch(1)

      assert ImportGate.created_initiative_ids(ops, nil) == %{}
      assert ImportGate.created_initiative_ids(ops, [%{"index" => 0, "status" => "ok"}]) == %{}
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

  describe "parent-anchored adds (m03.04 item 2.18)" do
    test "existing_parent_ids/1 lists unique bare parent_ids in batch order" do
      ops = [
        %{"op" => "add", "type" => "task", "lid" => "a", "data" => %{"parent_id" => 42}},
        %{"op" => "add", "type" => "task", "lid" => "b", "data" => %{"parent_id" => 42}},
        %{"op" => "add", "type" => "task", "lid" => "c", "data" => %{"parent_id" => 43}},
        # Carries its own Initiative ref — its parent_id is never consulted.
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "d",
          "data" => %{"parent_id" => 44, "initiative_id" => 9}
        },
        # Chases the in-batch parent instead.
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "e",
          "data" => %{"parent_id" => 45, "parent_lid" => "a"}
        },
        # Not a task-add.
        %{"op" => "update", "type" => "task", "id" => 1, "data" => %{"parent_id" => 46}}
      ]

      assert ImportGate.existing_parent_ids(ops) == [42, 43]
    end

    test "count_by_target/2 counts parent-anchored adds through the resolved map, mixed batch" do
      ops =
        task_adds(2, %{"initiative_id" => 9}) ++
          [
            %{"op" => "add", "type" => "task", "lid" => "p1", "data" => %{"parent_id" => 42}},
            %{"op" => "add", "type" => "task", "lid" => "p2", "data" => %{"parent_id" => 43}}
          ]

      assert ImportGate.count_by_target(ops, %{42 => {:existing, 9}, 43 => {:existing, 8}}) ==
               [{{:existing, 9}, 3}, {{:existing, 8}, 1}]
    end

    test "an in-batch parent_lid chain terminating at a parent_id resolves through the map" do
      ops = [
        %{"op" => "add", "type" => "task", "lid" => "root", "data" => %{"parent_id" => 42}},
        %{"op" => "add", "type" => "task", "lid" => "mid", "data" => %{"parent_lid" => "root"}},
        %{"op" => "add", "type" => "task", "lid" => "leaf", "data" => %{"parent_lid" => "mid"}}
      ]

      assert ImportGate.count_by_target(ops, %{42 => {:existing, 7}}) == [{{:existing, 7}, 3}]
      assert ImportGate.target_refs(ops, %{42 => {:existing, 7}}) == [{:existing, 7}]
    end

    test "a parent missing from the map stays dropped — the apply surfaces the real error" do
      ops = [
        %{"op" => "add", "type" => "task", "lid" => "a", "data" => %{"parent_id" => 42}},
        %{"op" => "add", "type" => "task", "lid" => "b", "data" => %{"parent_id" => 404}}
      ]

      assert ImportGate.count_by_target(ops, %{42 => {:existing, 7}}) == [{{:existing, 7}, 1}]
    end

    test "evaluate/2 gates an over-threshold parent-anchored batch through :parent_targets" do
      ops = task_adds(@threshold + 1, %{"parent_id" => 42})

      assert {:gate, %{task_adds: task_adds, target: {:existing, 7}}} =
               ImportGate.evaluate(ops,
                 parent_targets: %{42 => {:existing, 7}}
               )

      assert task_adds == @threshold + 1
    end
  end
end
