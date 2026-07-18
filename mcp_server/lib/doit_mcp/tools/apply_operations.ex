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
  same key replays that stored response instead of re-applying the batch.

  ## Import gate — big import into a knob-less Initiative

  The gate is armed by default (`DOITLIST_IMPORT_GATE=off` opts out) and its
  trigger is CUMULATIVE per Initiative across the session: chunking a big
  import under the cap doesn't slip past it — every applied batch's task-adds
  are recorded per target (`DoitMcp.ImportGate.Counter`), and the session
  total including the current batch is what crosses the 30-task threshold.

  When the total crosses it for an Initiative whose `ai_knobs` is still
  empty (created in this same batch, or fetched and found blank), the batch
  is held for the operator when your client supports elicitation. Without a
  `readback` it is rejected unapplied — re-call with `readback` (your
  one-paragraph statement of the import shape you're about to build) and
  `assumptions` (your assumption-tagged decisions, one string each). Those
  are then shown to the operator to confirm or correct: confirm applies the
  batch normally and settles that Initiative for the rest of the session;
  corrections (or a refusal) come back as the tool result with NOTHING
  applied — revise the batch to match and record the settled answers in the
  Initiative's `ai_knobs`, which stops this gate firing again for that
  project in any session. No answer within 5 minutes → nothing applied;
  retry when the operator is available. Clients without elicitation support
  skip the gate entirely.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias DoitMcp.{Client, Elicitation, ImportGate, ToolResult}
  alias DoitMcp.ImportGate.Counter

  # A human is reading the readback — give them a generous window.
  @confirm_timeout to_timeout(minute: 5)

  @confirm_schema %{
    "type" => "object",
    "properties" => %{
      "confirm" => %{
        "type" => "boolean",
        "description" => "true applies the import as read back; false holds it"
      },
      "corrections" => %{
        "type" => "string",
        "description" => "What to change instead — leaves the batch unapplied"
      }
    },
    "required" => ["confirm"]
  }

  @knobs_note "Import confirmed by the operator. Record the now-settled answers " <>
                "(the readback and assumptions as confirmed) in this Initiative's " <>
                "ai_knobs so this gate never fires again for this project."

  schema do
    field(:operations, {:list, :map}, required: true)
    field(:idempotency_key, :string, required: false)
    field(:readback, :string, required: false)
    field(:assumptions, {:list, :string}, required: false)
  end

  def execute(params, frame) do
    gate =
      ImportGate.evaluate(params.operations,
        elicitation?: &Elicitation.client_supports_elicitation?/0,
        fetch_initiative: fn id -> Client.get("/api/v1/initiatives/#{id}") end,
        cumulative: &Counter.cumulative/1,
        confirmed?: &Counter.confirmed?/1
      )

    case gate do
      :pass -> apply_batch(params, frame)
      {:gate, info} -> hold_for_confirmation(params, info, frame)
    end
  end

  defp apply_batch(params, frame, opts \\ []) do
    result =
      Client.operations(params.operations, idempotency_key: Map.get(params, :idempotency_key))

    # The counter is the gate's session memory: every batch that actually
    # applied feeds the cumulative trigger, so sub-threshold chunks add up.
    with {:ok, _} <- result do
      Counter.record(ImportGate.count_by_target(params.operations))
    end

    {:reply, response, frame} = ToolResult.reply_batch(frame, result)

    response =
      case {result, opts[:note]} do
        {{:ok, _}, note} when is_binary(note) -> Response.text(response, note)
        _ -> response
      end

    {:reply, response, frame}
  end

  defp hold_for_confirmation(params, info, frame) do
    case presence(Map.get(params, :readback)) do
      nil ->
        {:reply, Response.error(Response.tool(), readback_required_message(info)), frame}

      readback ->
        confirm_with_operator(params, readback, info, frame)
    end
  end

  defp confirm_with_operator(params, readback, info, frame) do
    message = confirmation_message(readback, Map.get(params, :assumptions) || [])

    case Elicitation.request(message, @confirm_schema, confirm_timeout()) do
      {:ok, %{"action" => "accept", "content" => content}} when is_map(content) ->
        handle_answer(params, content, info, frame)

      {:ok, %{"action" => "decline"}} ->
        not_applied(frame, %{
          message:
            "Operator declined the import — batch NOT applied. Ask what to change, " <>
              "settle the answers in the Initiative's ai_knobs, then re-apply."
        })

      _timeout_cancel_or_error ->
        not_applied(frame, %{
          message: "Operator did not respond; batch not applied — retry when they're available."
        })
    end
  end

  defp handle_answer(params, content, info, frame) do
    case {presence(content["corrections"]), content["confirm"]} do
      {nil, true} ->
        # The operator's confirm settles this Initiative for the rest of the
        # session — later chunks must not re-ask, even before the agent has
        # recorded ai_knobs (marked before the apply so a failed apply's
        # retry doesn't re-elicit an already-granted confirmation).
        Counter.mark_confirmed(info.target)
        apply_batch(params, frame, note: @knobs_note)

      {nil, _} ->
        not_applied(frame, %{
          message:
            "Operator answered confirm=false with no corrections — batch NOT applied. " <>
              "Ask what to change, update the Initiative's ai_knobs, then re-apply."
        })

      {corrections, _} ->
        not_applied(frame, %{
          corrections: corrections,
          message:
            "Operator supplied corrections — batch NOT applied. Revise the batch to " <>
              "match and record the settled answers in the Initiative's ai_knobs, then re-apply."
        })
    end
  end

  defp not_applied(frame, extra) do
    payload = Map.merge(%{ok: false, applied: false, gate: "import_readback_confirm"}, extra)
    response = Response.json(Response.tool(), payload)
    {:reply, %{response | isError: true}, frame}
  end

  defp readback_required_message(%{task_adds: task_adds, cumulative: cumulative}) do
    "Import gate: this batch adds #{task_adds} tasks (#{cumulative} this session, " <>
      "chunks included) to an Initiative whose ai_knobs is still empty, so the operator " <>
      "must confirm it before it applies. Nothing was " <>
      "applied. Re-call apply_operations with the same operations plus `readback` — " <>
      "your one-paragraph statement of the import shape you're about to build — and " <>
      "`assumptions` — your assumption-tagged decisions, one string each. The operator " <>
      "will confirm or correct them; record the settled answers in the Initiative's ai_knobs."
  end

  defp confirmation_message(readback, assumptions) do
    assumptions_block =
      case assumptions do
        [] -> "Assumptions: none stated."
        list -> "Assumptions:\n" <> Enum.map_join(list, "\n", &("- " <> &1))
      end

    "#{readback}\n\n#{assumptions_block}\n\nConfirm to apply this import, or supply corrections."
  end

  defp confirm_timeout do
    Application.get_env(:doit_mcp, :import_gate_confirm_timeout, @confirm_timeout)
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil
end
