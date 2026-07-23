defmodule DoitMcp.Tools.ApplyOperations do
  @moduledoc """
  Apply a raw, ordered batch of operations atomically (all-or-nothing) —
  a direct mirror of `POST /api/v1/operations`.

  This is the ONLY tool that supports `lid` (client-assigned local ids for
  forward references within the same batch — e.g. bootstrapping a new
  Initiative and its first task in one call) and multi-op batches; every
  other tool in this MCP server builds exactly one op against a real id.

  A batch is capped at **150 operations**; a larger batch is rejected up front
  with a `422` (naming the count and the limit) before any of it is applied.

  Before applying a bulk ingest or edit batch: if the doitlist skill is
  loaded, run its Ingest Checkpoint now — this is the moment of action. And
  batch the WHOLE pass — bulk completions, comments, and edits belong in
  batches too, not looped single-op calls to the per-op tools (that is the
  failure mode). Past the cap, split into chunks filled toward it; sub-cap
  chunking is fine — but lids resolve within one batch only, so reference
  across chunks by real id.

  Each element of `operations` must be a JSON object matching the wire
  format:

      %{
        "op" => "add" | "update" | "remove",
        "type" => "task" | "initiative" | "comment" | "member" | "notification" | "link",
        "id" => <int, for update/remove targeting a real resource>,
        "lid" => <string, for add — a batch-local reference other later ops
                  in the SAME call can point back to>,
        "data" => <op-specific fields, matching whichever domain tool
                   documents for that op/type>
      }

  ## Referencing a `lid` from a later op — the forward-reference mechanism

  Registering a `lid` on an `add` (above) is only half of it — here's how a
  LATER op in the same batch points back to it:

    * To target the created resource itself (an `update`/`remove` on it):
      put the same string in that op's own top-level `"lid"` field instead
      of `"id"` — e.g. `%{"op" => "update", "type" => "task", "lid" => "t1",
      "data" => %{"manual_progress" => 50}}`.
    * To reference it as a RELATIONSHIP inside another op's `data`: use a
      `<field>_lid` key instead of `<field>_id` — e.g. `"parent_lid" =>
      "t1"` instead of `"parent_id"` (a task's parent), `"initiative_lid" =>
      "i"` (a task's Initiative), `"source_lid"`/`"target_lid"` (a link's
      endpoints), `"task_lid"` (a comment's task).

  A lid only resolves to an EARLIER op's `add` of the matching `type` —
  never a later or wrong-type one. Worked example — bootstrap an Initiative
  and its first task, then mark it done, in one call:

      [
        %{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "New project"}},
        %{"op" => "add", "type" => "task", "lid" => "t1", "data" => %{"initiative_lid" => "i", "title" => "First task"}},
        %{"op" => "update", "type" => "task", "lid" => "t1", "data" => %{"done" => true}}
      ]

  This tool is a pure pass-through — the caller is responsible for building
  each op object correctly per the wire format above; no reshaping happens
  here.

  ## Safe retries — `idempotency_key`

  Pass an optional `idempotency_key` (any client-chosen string) to make a retry
  safe: it is forwarded as the `Idempotency-Key` header, so if a first attempt
  already committed but its response was lost (e.g. a timeout), a retry with the
  same key replays that stored response instead of re-applying the batch. The
  key binds to the exact payload — a revised batch takes a new key.

  ## Import gate — big-import confirmation

  The gate is armed by default (`DOITLIST_IMPORT_GATE=off` opts out) and its
  trigger is CUMULATIVE per Initiative across the session: chunking a big
  import under the cap doesn't slip past it — every applied batch's task-adds
  are recorded per target (`DoitMcp.ImportGate.Counter`), and the session
  total including the current batch is what crosses the 30-task threshold.
  Adds anchored on an EXISTING task's `parent_id` count too (m03.04 item
  2.18): the adapter resolves each unique parent to its Initiative through
  `GET /api/v1/tasks/:id` — one read per unique parent per batch — before
  the gate runs, so growing an existing tree can't dodge the threshold.
  An Initiative created mid-import keeps one total across chunks: its count
  (and any confirm the operator granted under its lid) follows it to the real
  id the response echoes, so later chunks referencing it by id keep
  accumulating.

  When the total crosses the threshold, the batch is held for the operator
  when your client supports elicitation. Without a `readback` it is rejected
  unapplied — re-call with `readback` (your one-paragraph statement of the
  import shape you're about to build), `assumptions` (your assumption-tagged
  decisions, one string each), and `settled` (dimensions already settled by
  the operator's own ask — an explicit depth, a "summarize" instruction —
  one string each; operator-instructed dimensions go in `settled`, never
  `assumptions`, and are displayed so the operator can veto a misclaimed
  tag). The operator answers with one of three decisions: **apply** applies
  the batch normally and settles that Initiative for the rest of the
  session; **correct** (or any corrections text) comes back as the tool
  result with NOTHING applied — revise the batch to match, then re-apply;
  **hold** means the operator wants to be interviewed first — ask your
  remaining questions, then re-apply. No answer within 5 minutes → nothing
  applied; retry when the operator is available. Clients without elicitation
  support skip the gate entirely. The confirm holds for the session; it is
  not persisted across sessions.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{BatchShape, Client, Elicitation, ImportGate, ToolResult}
  alias DoitMcp.ImportGate.Counter

  # A human is reading the readback — give them a generous window.
  @confirm_timeout to_timeout(minute: 5)

  @confirm_schema %{
    "type" => "object",
    "properties" => %{
      "decision" => %{
        "type" => "string",
        "enum" => ["apply", "correct", "hold"],
        "description" =>
          "apply = apply the import as read back; correct = don't apply, my corrections " <>
            "say what to change; hold = don't apply, I want the agent to ask me more " <>
            "questions first"
      },
      "corrections" => %{
        "type" => "string",
        "description" => "What to change instead — leaves the batch unapplied"
      }
    },
    "required" => ["decision"]
  }

  @confirm_note "Import confirmed by the operator for this session."

  schema do
    field(:operations, {:list, :map}, required: true)
    field(:idempotency_key, :string, required: false)
    field(:readback, :string, required: false)
    field(:assumptions, {:list, :string}, required: false)
    field(:settled, {:list, :string}, required: false)
  end

  def execute(params, frame) do
    # Content-shape pass first (m03.04 3.1 iteration 1): a refusal costs no
    # API reads, and a shape-hold forces the confirm even under the size
    # threshold. Rides the gate's kill switch — one switch disarms all import
    # guardrails.
    case shape_check(params) do
      {:refuse, message} ->
        {:reply, shape_refused(message), frame}

      shape ->
        parent_targets = resolve_parent_targets(params.operations)

        gate =
          ImportGate.evaluate(params.operations,
            elicitation?: &Elicitation.client_supports_elicitation?/0,
            fetch_initiative: fn id -> Client.get("/api/v1/initiatives/#{id}") end,
            cumulative: &Counter.cumulative/1,
            confirmed?: &Counter.confirmed?/1,
            parent_targets: parent_targets
          )

        case {gate, shape} do
          {{:gate, info}, _} ->
            hold_for_confirmation(params, info, parent_targets, frame)

          {:pass, :hold} ->
            # Shape-held below the size threshold: synthetic info, no target —
            # the confirm is about this batch's content, not a per-Initiative
            # session settling.
            adds = ImportGate.count_task_adds(params.operations)
            info = %{task_adds: adds, cumulative: adds, target: nil}
            hold_for_confirmation(params, info, parent_targets, frame)

          {:pass, :pass} ->
            apply_batch(params, parent_targets, frame)
        end
    end
  end

  # BatchShape verdict, folded with what the session can actually do:
  #   - refusals stand unless the agent claims an operator instruction
  #     (`readback` + `settled`) AND the client can ask the operator — the
  #     claim then routes to the confirm form, where the printed facts make a
  #     false "operator asked for this" vetoable at a glance (fix 18.2's
  #     precedent);
  #   - sub-scale holds step aside on a non-elicitation client, exactly like
  #     the size gate (condition 2) — with no way to ask, prose is the only
  #     layer there.
  defp shape_check(params) do
    if ImportGate.enabled?() do
      case BatchShape.classify(params.operations) do
        {:refuse, message} ->
          if override_claimed?(params) and Elicitation.client_supports_elicitation?(),
            do: :hold,
            else: {:refuse, message}

        {:hold, _question} ->
          if Elicitation.client_supports_elicitation?(), do: :hold, else: :pass

        :pass ->
          :pass
      end
    else
      :pass
    end
  end

  defp override_claimed?(params) do
    presence(Map.get(params, :readback)) != nil and (Map.get(params, :settled) || []) != []
  end

  defp shape_refused(message) do
    payload = %{ok: false, applied: false, gate: "batch_shape", message: message}
    response = Response.json(Response.tool(), payload)
    %{response | isError: true}
  end

  # Resolve the batch's parent-anchored task-adds (`parent_id` = an existing
  # task) to their Initiatives — one GET /api/v1/tasks/:id per unique parent
  # (m03.04 item 2.18). Built ONCE per call and reused by both the gate
  # evaluation and the post-apply Counter.record, so gate-time counting and
  # recorded counts can never drift. Skipped when the gate could never fire
  # (kill switch off, or a client without elicitation) — both fixed for the
  # session, so the counter stays consistent with what the gate would read.
  # A parent the read can't resolve (404/error) is left out of the map: its
  # adds keep the old dropped behavior and the apply surfaces the real error.
  defp resolve_parent_targets(operations) do
    with [_ | _] = parent_ids <- ImportGate.existing_parent_ids(operations),
         true <- ImportGate.enabled?() and Elicitation.client_supports_elicitation?() do
      parent_ids
      |> Enum.flat_map(fn parent_id ->
        case Client.get("/api/v1/tasks/#{parent_id}") do
          {:ok, %{"initiative_id" => initiative_id}} ->
            [{parent_id, {:existing, initiative_id}}]

          _ ->
            []
        end
      end)
      |> Map.new()
    else
      _ -> %{}
    end
  end

  defp apply_batch(params, parent_targets, frame, opts \\ []) do
    result =
      Client.operations(params.operations, idempotency_key: Map.get(params, :idempotency_key))

    # The counter is the gate's session memory: every batch that actually
    # applied feeds the cumulative trigger, so sub-threshold chunks add up.
    with {:ok, body} <- result do
      record_applied(params.operations, body, parent_targets)
    end

    {:reply, response, frame} = ToolResult.reply_batch(frame, result)

    response =
      case {result, opts[:note]} do
        {{:ok, _}, note} when is_binary(note) -> Response.text(response, note)
        _ -> response
      end

    {:reply, response, frame}
  end

  # Record the applied batch's per-target task-adds — through the SAME
  # parent_targets map the gate evaluated, so what's recorded is exactly what
  # was counted. An Initiative created in this batch was counted (and
  # possibly confirmed) under its lid, but later chunks can only reference it
  # by the real id the response echoes — rekey the counts and carry any
  # granted confirm across, or the session total (and the operator's answer)
  # would reset at the chunk boundary.
  defp record_applied(operations, body, parent_targets) do
    results = (is_map(body) && Map.get(body, "results")) || []
    created = ImportGate.created_initiative_ids(operations, results)

    operations
    |> ImportGate.count_by_target(parent_targets)
    |> ImportGate.rekey_counts(created)
    |> Counter.record()

    Enum.each(created, fn {lid, id} ->
      if Counter.confirmed?({:in_batch, lid}), do: Counter.mark_confirmed({:existing, id})
    end)
  end

  defp hold_for_confirmation(params, info, parent_targets, frame) do
    case presence(Map.get(params, :readback)) do
      nil ->
        {:reply, Response.error(Response.tool(), readback_required_message(info)), frame}

      readback ->
        confirm_with_operator(params, readback, info, parent_targets, frame)
    end
  end

  defp confirm_with_operator(params, readback, info, parent_targets, frame) do
    message =
      confirmation_message(
        readback,
        BatchShape.facts_block(params.operations),
        Map.get(params, :assumptions) || [],
        Map.get(params, :settled) || []
      )

    case Elicitation.request(message, @confirm_schema, confirm_timeout()) do
      {:ok, %{"action" => "accept", "content" => content}} when is_map(content) ->
        handle_answer(params, content, info, parent_targets, frame)

      {:ok, %{"action" => "decline"}} ->
        not_applied(frame, %{
          message:
            "Operator declined the import — batch NOT applied. Ask what to change, " <>
              "then re-apply."
        })

      _timeout_cancel_or_error ->
        not_applied(frame, %{
          message: "Operator did not respond; batch not applied — retry when they're available."
        })
    end
  end

  defp handle_answer(params, content, info, parent_targets, frame) do
    corrections = presence(content["corrections"])
    decision = content["decision"]

    cond do
      decision == "apply" and is_nil(corrections) ->
        # The operator's confirm settles this Initiative for the rest of the
        # session — later chunks must not re-ask (marked before the apply so a
        # failed apply's retry doesn't re-elicit an already-granted confirm).
        # A shape-hold has no target: its confirm is per-batch, nothing settles.
        if info.target, do: Counter.mark_confirmed(info.target)
        apply_batch(params, parent_targets, frame, note: @confirm_note)

      is_binary(corrections) ->
        not_applied(frame, %{
          corrections: corrections,
          message:
            "Operator supplied corrections — batch NOT applied. Revise the batch to " <>
              "match, then re-apply."
        })

      decision == "hold" ->
        not_applied(frame, %{
          message:
            "Operator chose hold — batch NOT applied. They want to be interviewed before " <>
              "this import: ask your remaining questions now (the question budget), " <>
              "then re-apply."
        })

      true ->
        not_applied(frame, %{
          message:
            "Operator did not choose apply and supplied no corrections — batch NOT applied. " <>
              "Ask what to change, then re-apply."
        })
    end
  end

  defp not_applied(frame, extra) do
    payload = Map.merge(%{ok: false, applied: false, gate: "import_readback_confirm"}, extra)
    response = Response.json(Response.tool(), payload)
    {:reply, %{response | isError: true}, frame}
  end

  defp readback_required_message(%{target: nil, task_adds: task_adds}) do
    "Import gate: this batch's content shape needs the operator's confirmation before " <>
      "its #{task_adds} task-adds apply (checkbox/description shape — the confirm form " <>
      "carries the specifics). Nothing was applied. Re-call apply_operations with the " <>
      "same operations plus `readback`, `assumptions`, and `settled`, as for a large import."
  end

  defp readback_required_message(%{task_adds: task_adds, cumulative: cumulative}) do
    "Import gate: this batch adds #{task_adds} tasks (#{cumulative} this session, " <>
      "chunks included), so the operator must confirm it before it applies. Nothing was " <>
      "applied. Re-call apply_operations with the same operations plus `readback` — " <>
      "your one-paragraph statement of the import shape you're about to build — " <>
      "`assumptions` — your assumption-tagged decisions, one string each — and " <>
      "`settled` — dimensions the operator's own ask already settled, " <>
      "one string each. The operator will confirm or correct them."
  end

  # Shape facts print directly under the agent's readback: claim first, then
  # the numbers that check it. Nil (an unremarkable batch) drops the section.
  defp confirmation_message(readback, shape_facts, assumptions, settled) do
    assumptions_block =
      case assumptions do
        [] -> "Assumptions: none stated."
        list -> "Assumptions:\n" <> Enum.map_join(list, "\n", &("- " <> &1))
      end

    settled_block =
      case settled do
        [] ->
          nil

        list ->
          "Settled (operator-instructed):\n" <> Enum.map_join(list, "\n", &("- " <> &1))
      end

    closing =
      "Decide: apply — apply this import as read back; correct — don't apply, " <>
        "your corrections say what to change; hold — don't apply, have the agent " <>
        "ask you more questions first."

    [readback, shape_facts, settled_block, assumptions_block, closing]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp confirm_timeout do
    Application.get_env(:doit_mcp, :import_gate_confirm_timeout, @confirm_timeout)
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil
end
