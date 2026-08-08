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

  Batch the WHOLE pass — bulk completions, comments, and edits belong in
  batches too, not looped single-op calls to the per-op tools (that is the
  failure mode). Past the cap, split into chunks filled toward it; sub-cap
  chunking is fine — but lids resolve within one batch only, so reference
  across chunks by real id.

  ## Import limits — the numbers, upfront

  The import gate (contract below) counts CUMULATIVE task-adds per target
  Initiative over a trailing time window — chunking doesn't reset it:

    * **The ramp — 32 / 128:** up to 32 task-adds flow on shape alone; the
      leash stretches to 128 while every batch delivers ONE coherent list —
      every add under a single parent, at most 32 adds. Bulk, mixed-parent,
      or oversized batches keep the tight bound and meet the readback
      confirm.
    * **Fresh floor — 8:** a just-created Initiative's first import meets
      the confirm past 8 cumulative task-adds, whatever the batch's
      coherence; the operator's one confirm settles the Initiative for the
      session, then the ramp applies.
    * **Description cap — 8000 characters** per task description, enforced
      by the API (a 422): trim the prose and cite the source doc's path in
      a provenance comment — never split the overflow into continuation
      tasks.
    * **Ideal import shape:** skeleton first — the Initiative and its
      top-level parents — then ~32-add chunks, one parent's children
      apiece, cut deterministically from the source's structure, each chunk
      carrying a provenance comment naming its source section. That shape
      rides the ramp and meets at most the one fresh-floor confirm.

  ## Wire format

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

  When the bootstrapped Initiative imports a hierarchical source, set
  `index_style` in its `data` to match the source's numbering scheme when it
  has a usable one (`outline`, `numerical`, `roman`, `alphabetical`); a
  hierarchy with no usable scheme takes `numerical`; a plain non-referenced
  list stays `none` (the default).

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
  trigger is CUMULATIVE per Initiative over a trailing time window: recent
  task creations are read from the DATABASE (`DoitMcp.ImportPressure`, via
  `GET /initiatives/:id/task_count?created_at=`), so chunking can't slip
  past it, reconnecting can't reset it, and a human-rhythm drip of creates
  decays out on its own. The recent count plus the current batch crosses the
  batch's bound: 32 normally, 128 for a coherent one-list batch (every add
  under one parent, at most 32 adds — each such unit lands as one reviewable
  increment; the ramp). A just-created Initiative (created within the
  trailing window, or in this very batch) meets the confirm once past 8
  cumulative task-adds regardless of batch coherence — the fresh floor: the
  operator adjudicates the interpretation at the start, their one confirm
  settles the Initiative for the session and the ramp applies from there; an
  Initiative that ages past the window earns the normal bounds. Adds
  anchored on an EXISTING task's `parent_id`
  count too (m03.04 item 2.18): the adapter resolves each unique parent to
  its Initiative through `GET /api/v1/tasks/:id` — one read per unique
  parent per batch — before the gate runs, so growing an existing tree can't
  dodge the threshold. A confirm the operator granted under a fresh
  Initiative's lid follows it to the real id the response echoes.

  When the total crosses the threshold, the batch is held for the operator —
  for EVERY client (m03.04 item 30): the confirm resolves in the app,
  server-recorded, so no client capability is load-bearing. Without a
  `readback` the batch is rejected unapplied — re-call with `readback` (your
  one-paragraph statement of the import shape you're about to build),
  `assumptions` (your assumption-tagged decisions, one string each), and
  `settled` (dimensions already settled by the operator's own ask — an
  explicit depth, a "summarize" instruction — one string each;
  operator-instructed dimensions go in `settled`, never `assumptions`, and
  are displayed so the operator can veto a misclaimed tag). WITH a readback
  the call returns promptly, nothing applied, with `status:
  "confirmation_pending"`, the composed readback, and `confirm_url` — the
  server has PARKED the confirm behind the API, and the URL is where the
  operator decides. Two channels can answer it, first answer wins:

    * **In-app (always works):** show the operator the readback in chat,
      verbatim, and hand them the `confirm_url` — the app renders the same
      readback as a card with Approve / Correct / Hold. Their decision is
      recorded server-side; when they've decided, re-call with the SAME
      operations and the server's answer resolves the batch — approve
      applies it and settles that Initiative for the session; correct
      returns their text (revise, then re-apply); hold applies nothing —
      ask your remaining questions, then re-apply (the re-ask re-parks).
    * **Elicitation form (convenience):** clients that render elicitation
      also get a confirm form carrying the same text; a form answer counts
      the same, remembered by the session, so a plain re-call flows. The
      form expires after 10 minutes; the in-app confirm has no clock.

  The decision channel is deliberately one-way: the adapter can only park a
  confirm and read its state — deciding is not writable through the API, so
  no agent can approve its own confirm.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias DoitMcp.{BatchShape, Client, Elicitation, ImportGate, ImportPressure, ToolResult}
  alias DoitMcp.ImportGate.{Counter, PendingConfirm}

  # The out-of-band confirm form's lifetime (m03.04 item 27.2) — generous,
  # human-paced, retunable; the in-app confirm (item 30) has no clock and
  # keeps working after the form lapses.
  @confirm_form_expiry to_timeout(minute: 10)

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

  @pending_instructions "Nothing applied yet — the operator must decide first. Show them " <>
                          "this result's `readback` in chat, verbatim, and hand them the " <>
                          "`confirm_url` — they decide there, in the app (Approve / Correct / " <>
                          "Hold); the server records it. A confirm form may also have reached " <>
                          "your client; answering it counts the same — first answer wins. " <>
                          "When they've decided, re-call apply_operations with the SAME " <>
                          "operations — the server knows their decision and the re-call " <>
                          "resolves it."

  @marker_guidance "If the repo's agent-instruction file (CLAUDE.md, AGENTS.md) has no " <>
                     "'## Do It List' marker, offer the operator to add it:"

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
            # AI-KNOBS-PARKED (m03.04): revive re-adds fetch_initiative (knobs-exemption read).
            # Recent pressure comes from the DATABASE's inserted_at window
            # (m03.04 3.1 iteration 2) — human-rhythm drips decay, gulps
            # weigh full, and reconnects can't reset it.
            cumulative: &ImportPressure.recent/1,
            confirmed?: &Counter.confirmed?/1,
            # Freshness reads the same DB fact as pressure — a reconnect
            # can't blank it.
            fresh?: &ImportPressure.fresh?/1,
            parent_targets: parent_targets
          )

        case {gate, shape} do
          {{:gate, info}, _} ->
            hold_for_confirmation(params, info, frame, parent_targets)

          {:pass, :hold} ->
            # Shape-held below the size threshold: synthetic info, no target —
            # the confirm is about this batch's content, not a per-Initiative
            # session settling. A form approval marked this exact batch's key
            # in the Counter, so its re-call flows here.
            if Counter.confirmed?(confirm_key(params.operations)) do
              apply_batch(params, frame, parent_targets, note: @confirm_note)
            else
              adds = ImportGate.count_task_adds(params.operations)
              info = %{task_adds: adds, cumulative: adds, target: nil, fresh: false}
              hold_for_confirmation(params, info, frame, parent_targets)
            end

          {:pass, :pass} ->
            apply_batch(params, frame, parent_targets)
        end
    end
  end

  # BatchShape verdict, folded with the confirm contract:
  #   - refusals stand unless the agent claims an operator instruction
  #     (`readback` + `settled`) — the claim then routes to the confirm,
  #     where the printed facts make a false "operator asked for this"
  #     vetoable at a glance (fix 18.2's precedent);
  #   - sub-scale holds always hold (m03.04 item 30.4): the in-app confirm
  #     can ask the operator on any client, so no capability steps a hold
  #     aside anymore.
  defp shape_check(params) do
    if ImportGate.enabled?() do
      case BatchShape.classify(params.operations) do
        {:refuse, message} ->
          if override_claimed?(params), do: :hold, else: {:refuse, message}

        {:hold, _question} ->
          :hold

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
  # (m03.04 item 2.18) — for the gate's per-target counting. Skipped when the
  # gate could never fire (kill switch off). A parent the read can't resolve
  # (404/error) is left out of the map: its adds keep the old dropped
  # behavior and the apply surfaces the real error.
  defp resolve_parent_targets(operations) do
    with [_ | _] = parent_ids <- ImportGate.existing_parent_ids(operations),
         true <- ImportGate.enabled?() do
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

  defp apply_batch(params, frame, parent_targets, opts \\ []) do
    result =
      Client.operations(params.operations, idempotency_key: Map.get(params, :idempotency_key))

    {:reply, response, frame} = ToolResult.reply_batch(frame, result)

    response =
      case result do
        {:ok, body} ->
          # Pressure now lives in the DATABASE (inserted_at window) — applied
          # adds count themselves. Only the operator's confirm needs carrying:
          # granted under a fresh Initiative's lid, later chunks reference the
          # real id.
          created = carry_confirms(params.operations, body)

          response
          |> append_note(opts[:note])
          |> suggest_marker(params.operations, created, parent_targets)

        _ ->
          response
      end

    {:reply, response, frame}
  end

  defp carry_confirms(operations, body) do
    results = (is_map(body) && Map.get(body, "results")) || []
    created = ImportGate.created_initiative_ids(operations, results)

    Enum.each(created, fn {lid, id} ->
      if Counter.confirmed?({:in_batch, lid}), do: Counter.mark_confirmed({:existing, id})
    end)

    created
  end

  defp append_note(response, note) when is_binary(note), do: Response.text(response, note)
  defp append_note(response, _note), do: response

  # An import-shaped apply — task-adds resolved to their target Initiatives,
  # the gate's own classification reused, never re-derived — ends with the
  # repo-marker suggestion (m03.04 item 26.2): the guidance line plus the
  # server-composed marker, read from the initiative list's `repo_marker`
  # field so the wording never forks from the panel. Once per Initiative per
  # session (Counter); the repo-file check and the offer are the agent's.
  # Edit batches resolve no target and stay clean.
  defp suggest_marker(response, operations, created, parent_targets) do
    ids =
      operations
      |> ImportGate.target_refs(parent_targets)
      |> Enum.flat_map(fn
        {:existing, id} -> [id]
        {:in_batch, lid} -> List.wrap(created[lid])
      end)
      |> Enum.uniq()
      |> Enum.reject(&Counter.confirmed?({:repo_marker, &1}))

    Enum.reduce(markers_for(ids), response, fn {id, marker}, response ->
      Counter.mark_confirmed({:repo_marker, id})
      Response.text(response, @marker_guidance <> "\n\n" <> marker)
    end)
  end

  # The one list read sourcing the markers — only when something will be
  # emitted, never per-op. A failed read or a marker-less summary drops the
  # suggestion (fail-open, ImportPressure's precedent).
  defp markers_for([]), do: []

  defp markers_for(ids) do
    case Client.get("/api/v1/initiatives") do
      {:ok, summaries} when is_list(summaries) ->
        markers =
          for %{"id" => id, "repo_marker" => marker} <- summaries,
              is_binary(marker),
              into: %{},
              do: {id, marker}

        for id <- ids, is_binary(markers[id]), do: {id, markers[id]}

      _ ->
        []
    end
  end

  # A held batch never waits on its confirm (m03.04 item 27.1): the answer
  # arrives on the session's own channels — the out-of-band form via the
  # detached waiter — or in the APP (item 30): the confirm is parked behind
  # the API and the operator's decision is server-recorded, consulted here
  # by payload hash on every re-call. Session channels first (first answer
  # wins), then the server's record.
  defp hold_for_confirmation(params, info, frame, parent_targets) do
    key = confirm_key(params.operations)

    case PendingConfirm.take_answered(key) do
      {:answered, outcome} ->
        form_outcome(outcome, frame)

      :none ->
        consult_confirm(params, key, info, frame, parent_targets)
    end
  end

  # The server-recorded confirm (m03.04 item 30.1): `GET` the newest row for
  # this exact batch's hash. An approval is honored wherever it was granted
  # — another session, another client, before an adapter restart — because
  # the server knows; decisions are not writable through this API, so no
  # agent can have written it. A consult failure is LOUD (never a silent
  # pass); 404 just means nothing is parked yet.
  defp consult_confirm(params, key, info, frame, parent_targets) do
    case Client.get("/api/v1/import_confirms/#{payload_hash(params.operations)}") do
      {:ok, %{"status" => "approved"}} ->
        # Settle exactly as a form grant does: the gate's target (the
        # session settle) plus this exact batch's key (so a shape-held
        # re-call flows too), marked before the apply so a failed apply's
        # retry doesn't re-ask.
        PendingConfirm.claim(key)
        if info.target, do: Counter.mark_confirmed(info.target)
        Counter.mark_confirmed(key)
        apply_batch(params, frame, parent_targets, note: @confirm_note)

      {:ok, %{"status" => "corrected"} = row} ->
        decided_outcome(
          %{decision: "correct", corrections: presence(row["corrections"])},
          key,
          params,
          info,
          frame
        )

      {:ok, %{"status" => "held"}} ->
        decided_outcome(%{decision: "hold", corrections: nil}, key, params, info, frame)

      {:ok, %{"status" => "pending"}} ->
        # Already parked (this session or an earlier one): don't double-park
        # — the park POST is idempotent, so the park path returns the same
        # row and URL (and re-arms the form where one can ride).
        pending_or_park(params, key, info, frame)

      {:error, %{status: 404}} ->
        pending_or_park(params, key, info, frame)

      {:error, _} ->
        confirm_channel_down(frame)
    end
  end

  # A recorded correct/hold resolves ONCE per outstanding confirm — the form
  # outcomes' exact semantics: consumed on pickup, so the NEXT re-call of
  # the same batch re-parks a fresh confirm (the re-ask; the park POST opens
  # a fresh pending row past a decided one). With nothing outstanding on
  # this session (a fresh session, or already consumed), the decided row is
  # history — re-ask by parking.
  defp decided_outcome(outcome, key, params, info, frame) do
    case PendingConfirm.claim(key) do
      :pending -> form_outcome(outcome, frame)
      {:answered, form} -> form_outcome(form, frame)
      :none -> pending_or_park(params, key, info, frame)
    end
  end

  defp pending_or_park(params, key, info, frame) do
    if is_nil(presence(Map.get(params, :readback))) do
      {:reply, Response.error(Response.tool(), readback_required_message(info)), frame}
    else
      park_for_confirmation(params, key, info, frame)
    end
  end

  # Park the confirm behind the API (m03.04 item 30.1) — readback verbatim,
  # hash-bound, homed on the target Initiative (account for bootstrap
  # batches) — then return promptly with the readback and the confirm URL: a
  # NORMAL result carrying the operator's decision contract, never a park
  # inside the transport's dispatch bound. The elicitation form rides as a
  # parallel convenience where it can; a park failure is LOUD — with no
  # parked confirm there is nothing the operator could answer.
  defp park_for_confirmation(params, key, info, frame) do
    message =
      confirmation_message(
        presence(Map.get(params, :readback)),
        BatchShape.facts_block(params.operations),
        target_style_line(info.target),
        Map.get(params, :assumptions) || [],
        Map.get(params, :settled) || []
      )

    case Client.post("/api/v1/import_confirms", park_body(params.operations, message, info)) do
      {:ok, %{"url" => url}} ->
        PendingConfirm.open(key)
        send_form_where_it_rides(message, key, info.target)

        payload = %{
          ok: false,
          applied: false,
          gate: "import_readback_confirm",
          status: "confirmation_pending",
          readback: message,
          confirm_url: url,
          message: @pending_instructions
        }

        {:reply, Response.json(Response.tool(), payload), frame}

      _error ->
        confirm_channel_down(frame)
    end
  end

  # Only an EXISTING target homes the confirm on its Initiative; a bootstrap
  # batch (in-batch target) and a shape-hold (no target) home on the account
  # — their Initiative doesn't exist yet / isn't the confirm's subject.
  defp park_body(operations, message, info) do
    base = %{payload_hash: payload_hash(operations), readback: message}

    case info.target do
      {:existing, id} -> Map.put(base, :initiative_id, id)
      _ -> base
    end
  end

  # The form is a convenience channel (m03.04 item 30.4): it rides only when
  # the client advertised elicitation AND the session holds an open stream;
  # anywhere it can't — no capability, no stream, a send that loses the race
  # — the in-app URL is the channel, so every failure here is a quiet no-op,
  # never a hold. `:already_waiting` means a form is already out for this
  # session; the parked row and URL cover the rest.
  defp send_form_where_it_rides(message, key, target) do
    if Elicitation.client_supports_elicitation?() and Elicitation.reachable?() do
      on_answer = fn result -> form_answer(key, target, result) end
      Elicitation.request_async(message, @confirm_schema, confirm_expiry(), on_answer)
    end

    :ok
  end

  defp confirm_channel_down(frame) do
    not_applied(frame, %{
      message:
        "Import gate: this batch needs the operator's confirmation, but the confirm " <>
          "channel is unavailable — the app's import-confirm API could not be reached. " <>
          "Batch NOT applied. Re-call when the Do It List server is reachable; the " <>
          "operator will decide in the app."
    })
  end

  # Runs IN the detached waiter when the client's form answers, with the
  # gated request's session identity adopted — Counter and PendingConfirm
  # read the same session rows the tool call did. An approval marks the
  # gate's target (the session settle) plus this exact batch's key (so a
  # shape-held re-call flows too); decline/correct/hold latch on the row for
  # the next re-call to pick up. A stale answer — expired, superseded, or
  # beaten by the in-app decision — is dropped where it lands.
  defp form_answer(key, target, result) do
    case result do
      %{"action" => "accept", "content" => content} when is_map(content) ->
        corrections = presence(content["corrections"])

        if content["decision"] == "apply" and is_nil(corrections) do
          form_grant(key, target)
        else
          record_form_outcome(key, %{decision: content["decision"], corrections: corrections})
        end

      %{"action" => "decline"} ->
        record_form_outcome(key, %{decision: "decline", corrections: nil})

      _cancel_or_other ->
        # The form was dismissed, not decided — the in-app confirm stays
        # open on the parked row, and a plain re-call re-arms a fresh form.
        :ok
    end
  end

  defp form_grant(key, target) do
    case PendingConfirm.claim(key) do
      :pending ->
        if target, do: Counter.mark_confirmed(target)
        Counter.mark_confirmed(key)

      _stale_or_answered ->
        Logger.info("import confirm form approval arrived stale — ignored")
    end
  end

  defp record_form_outcome(key, outcome) do
    case PendingConfirm.form_answered(key, outcome) do
      :ok -> :ok
      :stale -> Logger.info("import confirm form answer arrived stale — ignored")
    end
  end

  # A recorded decision picked up by a re-call — form or in-app, the same
  # guidance either way.
  defp form_outcome(outcome, frame) do
    cond do
      is_binary(outcome[:corrections]) ->
        not_applied(frame, %{
          corrections: outcome[:corrections],
          message:
            "Operator supplied corrections — batch NOT applied. Revise the batch to " <>
              "match, then re-apply."
        })

      outcome[:decision] == "decline" ->
        not_applied(frame, %{
          message:
            "Operator declined the import — batch NOT applied. Ask what to change, " <>
              "then re-apply."
        })

      outcome[:decision] == "hold" ->
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

  # The pending confirm binds to the exact batch read back. Two identities,
  # two scopes: `confirm_key/1` (phash2) keys the SESSION rows —
  # Counter/PendingConfirm — and `payload_hash/1` (sha256 hex) is the
  # portable identity the API row carries, computed exactly as pinned so a
  # changed batch re-parks and an unchanged one resolves.
  defp confirm_key(operations), do: {:import_batch, :erlang.phash2(operations)}

  defp payload_hash(operations) do
    :crypto.hash(:sha256, :erlang.term_to_binary(operations, [:deterministic]))
    |> Base.encode16(case: :lower)
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

  # The fresh floor's clause must precede the generic volume clause — a
  # fresh-gated map carries the same task_adds/cumulative keys.
  defp readback_required_message(%{fresh: true, task_adds: task_adds, cumulative: cumulative}) do
    "Import gate: this Initiative was just created, so its first import needs the " <>
      "operator's confirmation once it passes #{ImportGate.fresh_threshold()} cumulative " <>
      "task-adds — this batch adds #{task_adds} (#{cumulative} this session). Nothing was " <>
      "applied. Re-call apply_operations with the same operations plus `readback` — name " <>
      "the SOURCE you are importing from, the selection you resolved from the operator's " <>
      "ask (which parts, and why those), and the planned coverage and depth — plus " <>
      "`assumptions` (assumption-tagged decisions, one string each) and `settled` " <>
      "(dimensions the operator's own ask already settled, one string each). One confirm " <>
      "settles this Initiative for the session."
  end

  defp readback_required_message(%{task_adds: task_adds, cumulative: cumulative}) do
    "Import gate: this batch adds #{task_adds} tasks (#{cumulative} this session, " <>
      "chunks included), so the operator must confirm it before it applies. Nothing was " <>
      "applied. Re-call apply_operations with the same operations plus `readback` — " <>
      "your one-paragraph statement of the import shape you're about to build — " <>
      "`assumptions` — your assumption-tagged decisions, one string each — and " <>
      "`settled` — dimensions the operator's own ask already settled, " <>
      "one string each. The operator will confirm or correct them. Alternatively: " <>
      "batches that deliver one list at a time (every add under one parent, at most " <>
      "#{ImportGate.threshold()} adds) flow without confirmation up to " <>
      "#{ImportGate.ramp_threshold()} cumulative."
  end

  # An EXISTING target's index_style, printed beneath the shape facts so the
  # confirm shows how the imported tree will render there. One read per HELD
  # batch only — this runs solely on the elicitation path. A failed read or a
  # response without the key drops the line (fail-open, ImportPressure's
  # precedent); an in-batch target's style is already a shape fact, and a
  # shape-hold (nil target) has no Initiative to read.
  defp target_style_line({:existing, id}) do
    case Client.get("/api/v1/initiatives/#{id}/task_count") do
      {:ok, %{"initiative_index_style" => "none"}} ->
        "- Target Initiative index_style: none — tasks render unnumbered."

      {:ok, %{"initiative_index_style" => style}} when is_binary(style) ->
        "- Target Initiative index_style: #{style}."

      _ ->
        nil
    end
  end

  defp target_style_line(_target), do: nil

  # Shape facts print directly under the agent's readback: claim first, then
  # the numbers that check it. Nil (an unremarkable batch) drops the section;
  # the target-style line rides the same nil-dropping join, so it still
  # prints when the shape facts don't.
  defp confirmation_message(readback, shape_facts, target_style, assumptions, settled) do
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

    [readback, shape_facts, target_style, settled_block, assumptions_block, closing]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp confirm_expiry do
    Application.get_env(:doit_mcp, :import_gate_confirm_expiry, @confirm_form_expiry)
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil
end
