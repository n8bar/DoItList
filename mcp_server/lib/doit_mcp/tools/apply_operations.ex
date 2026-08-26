defmodule DoitMcp.Tools.ApplyOperations do
  @moduledoc """
  Atomically apply up to 150 ordered operations. Always use this tool for multi-operation passes and `lid` references; every other tool submits one operation against a real id.

  Always batch the whole pass, including bulk completions, comments, and edits. Never loop per-operation tools. If the pass exceeds 150 operations, split it into batches filled toward the cap. A `lid` resolves only within its batch; always use returned real ids across batches.

  ## Import rules

  Import classification counts cumulative task-adds per target Initiative over a trailing time window; chunking never resets the count.

    * Task descriptions are limited to 8000 characters. If source prose exceeds the limit, trim it and cite the source document in the branch's provenance comment. Never create continuation tasks for overflow.
    * Always import the source whole, including completed items as `done: true`; otherwise roll-up progress lies.
    * Always keep a parent and its subtree in one batch by `lid` when the subtree fits within the 150-operation cap. Split only when the subtree alone exceeds the cap.
    * Add exactly one provenance comment per branch naming its source section.

  ## Wire format

  Each operation is a JSON object with these fields:

      {
        "op": "add" | "update" | "remove",
        "type": "task" | "initiative" | "comment" | "member" | "notification" | "link",
        "id": <real id for updating or removing an existing resource>,
        "lid": <batch-local id assigned by an add or used by a later same-batch update/remove to target that add>,
        "data": <fields documented by the corresponding domain tool>
      }

  ## Batch-local references

  Assign a unique `lid` to an add when later operations in the same batch must reference it.

    * To update or remove an earlier add, put its `lid` in the later operation's top-level `"lid"` instead of `"id"`.
    * To use an earlier add in a relationship, replace `<field>_id` with `<field>_lid`, such as `parent_lid`, `initiative_lid`, `task_lid`, `source_lid`, or `target_lid`.
    * For references between tasks added in the same batch, always add both tasks before their link operations, then use `source_lid` and `target_lid`. For mutual references, add one link per direction.

  A `lid` always resolves to an earlier add of the required type. Never reference a later add, reuse a `lid`, or carry one across batches. Across batches, always use real ids.

  A `lid` never replaces the numeric id inside a `%<task_id>` text reference. When new task text must reference another new task, add the tasks first and update the text after their real ids return.

  Always set `done` in the task's add or update that performs the completion. Never add a task and complete it with a second operation.

  When an Initiative added in this batch imports a hierarchical source, always set `index_style` to the source's usable scheme: `outline`, `numerical`, `roman`, or `alphabetical`. Use `numerical` for hierarchy without a usable scheme and `none` for a plain, non-referenced list.

  ## Conditional updates — `expected_version`

  For every task or Initiative update, always pass the latest read's `version` as `expected_version` unless overwriting any intervening change is acceptable. A stale version rolls back the entire batch and returns the current record under `current`; always reconcile that record before retrying.

  ## Safe retries — `idempotency_key`

  When a batch may be retried after a timeout or lost response, always give it a unique `idempotency_key`. Retry only the unchanged batch with the same key; the server replays a committed response instead of applying it again. Never reuse the key for a different batch.

  ## Import readback

  When the cumulative classifier flags an import batch, always include `readback` unless an accepted first-import declaration replaces it. State the source scope, task hierarchy and grain, and treatment of completed or excluded items in one paragraph. An operator-approved content exception still requires `readback`.

  Classification counts recent database task-adds per target Initiative, including adds beneath an existing task. Chunking and reconnecting never reset the count.

  Without the required `readback`, the server refuses the batch unapplied. Re-call with the same operations and `readback`. Use `assumptions` only for agent-made decisions and `settled` only for explicit operator instructions, with one decision per string.

  The readback requirement never stops an import for operator approval. The server applies the batch immediately, posts the record as a provenance comment on the target Initiative's root task, and settles later chunks for the session. First-import exclusions and content refusals are separate approval exceptions.

  ## First-import declaration and approval exceptions

  When an Initiative has fewer than 10 live tasks, no declaration on record, and its first import reaches 10 cumulative task-adds, always provide:

    * `declared_sources`: every source document read, each as `{path, checkbox_lines}` with checkbox lines counted from that file, never from the planned import.
    * `declared_total`: every item the source contains.
    * `declared_completed`: every item the source marks complete.
    * `declared_exclusions`: omitted items as `{count, reason}` objects; omit this field for a whole import.
    * `declared_ordering`: the source's ordering scheme, or `none` for an unordered source.

  Every chunk is checked against the declaration. Cumulative task-adds must not exceed `declared_total` minus declared exclusions, and every imported completed item must arrive as `done: true`. If the numbers cannot reconcile, fix the batch; if the declaration misstates the source, tell the operator.

  An accepted declaration becomes the root provenance record and replaces prose `readback` unless an operator-approved content exception also applies. When a completed import leaves declared-complete work in its exclusions, the server parks it and returns an approval URL. Include the completed items as `done: true`, or wait for the operator to approve in the app and then re-send the same batch unchanged. A dismissed payload remains refused.

  File-mirror, embedded-checklist, and boilerplate imports are also refused and parked. Always follow the refusal's recovery unless the operator explicitly requires the exact rejected content. Only the operator may approve that exception in the app; after approval, re-send the same batch unchanged. Never attest on the operator's behalf.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias DoitMcp.{BatchShape, Client, ImportGate, ImportInterview, ImportPressure, ToolResult}
  alias DoitMcp.ImportGate.Counter

  @record_prefix "Import record — readback as applied:"

  @declaration_prefix "Import record — declaration as accepted:"

  @record_note "Import record posted as a provenance comment on the target Initiative's root task."

  @record_fallback "The batch applied, but its import record was not posted. Always call `add_comment` on the target Initiative's `root_task_id` with this record text:"

  @marker_guidance "Always check the repo's agent-instruction file (`CLAUDE.md` or `AGENTS.md`) for a '## Do It List' marker. If absent, offer the operator this marker; never add it without approval:"

  schema do
    field(:operations, {:list, :map}, required: true)
    field(:idempotency_key, :string, required: false)
    field(:readback, :string, required: false)
    field(:assumptions, {:list, :string}, required: false)
    field(:settled, {:list, :string}, required: false)
    field(:declared_sources, {:list, :map}, required: false)
    field(:declared_total, :integer, required: false)
    field(:declared_completed, :integer, required: false)
    field(:declared_exclusions, {:list, :map}, required: false)
    field(:declared_ordering, :string, required: false)
  end

  def execute(params, frame) do
    # Content-shape pass first (m03.04 3.1 iteration 1): a refusal costs no
    # API reads. Rides the classifier's kill switch — one switch disarms all
    # import guardrails.
    case shape_check(params) |> shape_approval(params) do
      {:refuse, message} ->
        {:reply, shape_refused(message), frame}

      {:refuse, message, extra} ->
        {:reply, shape_refused(message, extra), frame}

      shape ->
        parent_targets = resolve_parent_targets(params.operations)
        # AI-KNOBS-PARKED (m03.04): revive re-adds fetch_initiative (knobs-exemption read).
        # Recent pressure comes from the DATABASE's inserted_at window
        # (m03.04 3.1 iteration 2) — human-rhythm drips decay, gulps weigh
        # full, and reconnects can't reset it. One snapshot read per target
        # serves the gate AND the first-import interview (2.8.10).
        snapshots = target_snapshots(params.operations, parent_targets)

        gate =
          ImportGate.evaluate(params.operations,
            cumulative: fn target -> snapshot(snapshots, target).recent end,
            confirmed?: &Counter.confirmed?/1,
            parent_targets: parent_targets
          )

        flavored? = import_flavored?(gate, params.operations, parent_targets)

        case interview(params, parent_targets, snapshots, gate) do
          {:refuse, message} ->
            {:reply, interview_refused(message), frame}

          {:refuse, message, extra} ->
            {:reply, interview_refused(message, extra), frame}

          {:ok, interview} ->
            case record_demand(gate, shape, params, parent_targets, interview) do
              :none ->
                apply_batch(params, frame, parent_targets,
                  interview: interview,
                  import_flavored: flavored?
                )

              {:missing_readback, message} ->
                {:reply, readback_refused(message), frame}

              {:record, record} ->
                apply_batch(params, frame, parent_targets,
                  record: record,
                  interview: interview,
                  import_flavored: flavored?
                )
            end
        end
    end
  end

  # BatchShape's verdict, unfolded (m03.04 2.8.5.3 retired the agent-asserted
  # `operator_confirmed` override): a refusal stands on its own here and the
  # operator's own click decides it in `shape_approval/2`.
  defp shape_check(params) do
    if ImportGate.enabled?() do
      BatchShape.classify(params.operations)
    else
      :pass
    end
  end

  # The shape refusal's override, riding 2.8.8's park-and-approve exactly as
  # the declared-exclusion gate does (m03.04 2.8.5.3): the operator's
  # recorded decision for this exact payload hash settles it. `skipped` means
  # the account's ceremony is dormant (2.8.9, the family this gate was built
  # to inherit) so the batch flows; approved flows stamped; dismissed latches
  # the declined refusal; anything else (re-)parks. Costs API reads only on
  # the refusal path — a passing batch still reaches the wire untouched.
  defp shape_approval(:pass, _params), do: :pass

  defp shape_approval({:refuse, message}, params) do
    case Client.get("/api/v1/import_approvals/#{payload_hash(params.operations)}") do
      {:ok, %{"status" => "skipped"}} ->
        :pass

      {:ok, %{"status" => "approved"}} ->
        :approved

      {:ok, %{"status" => "dismissed"} = row} ->
        {:refuse, shape_declined_message(row["decision_reason"])}

      _pending_or_none ->
        park_shape(params, message)
    end
  end

  defp park_shape(params, message) do
    body = %{
      payload_hash: payload_hash(params.operations),
      task_count: Enum.count(params.operations, &task_add_op?/1),
      initiative_name: BatchShape.first_initiative_name(params.operations),
      sample: BatchShape.deep_sample(params.operations)
    }

    case Client.post("/api/v1/import_approvals", body) do
      {:ok, %{"url" => url}} ->
        {:refuse, message, %{approve_url: url}}

      failure ->
        Logger.warning("shape refusal park failed: #{inspect(failure)}")
        park_failed(message)
    end
  end

  defp park_failed(message),
    do:
      {:refuse,
       message <>
         " The approval request was not created. Re-send the same batch unchanged to retry."}

  defp task_add_op?(%{"op" => "add", "type" => "task"}), do: true
  defp task_add_op?(_), do: false

  # The operator's own words, quoted and attributed — guidance from them, not
  # instructions from the server (m03.04 3.1.9.2). No words, no quote.
  defp shape_declined_message(reason) when is_binary(reason) do
    "Import content refused — nothing was applied. The operator rejected this exact import in the app: \"#{reason}\" Never re-send it unchanged. Revise it to follow their reason, or ask them to resolve any ambiguity."
  end

  defp shape_declined_message(_reason) do
    "Import content refused — nothing was applied. The operator rejected this exact import in the app without a reason. Never re-send it unchanged. Import the work inside the documents as tasks, preserving the source nesting, or ask the operator how to proceed."
  end

  # --- The first-import interview (m03.04 2.8.10) ----------------------------

  # One target snapshot read per batch (`ImportPressure.snapshot/1` — the
  # same windowed task_count read the gate always made) serving recent
  # pressure, the interview's done/live/declaration facts, and the park's
  # Initiative name. Skipped entirely under the kill switch.
  defp target_snapshots(operations, parent_targets) do
    if ImportGate.enabled?() do
      operations
      |> ImportGate.target_refs(parent_targets)
      |> Map.new(&{&1, ImportPressure.snapshot(&1)})
    else
      %{}
    end
  end

  @zero_snapshot %{recent: 0, recent_done: 0, live: nil, name: nil, declaration: nil}

  defp snapshot(snapshots, target), do: Map.get(snapshots, target, @zero_snapshot)

  # Decide the interview per target: a target in first-import scope (live
  # tree under the floor, no recorded declaration, cumulative adds at the
  # floor) demands the structured declaration; a target whose recorded
  # declaration is still live (window active) has this chunk checked against
  # it. Returns `{:ok, nil}` (no interview business), `{:ok, interview}`
  # (an accepted declaration to record and stamp), or a refusal.
  defp interview(params, parent_targets, snapshots, gate) do
    if ImportGate.enabled?() do
      counts = ImportGate.count_by_target(params.operations, parent_targets)
      done_counts = ImportGate.done_by_target(params.operations, parent_targets)

      Enum.reduce_while(counts, {:ok, nil}, fn {target, adds}, acc ->
        snap = snapshot(snapshots, target)
        cumulative = adds + snap.recent
        done = Map.get(done_counts, target, 0) + snap.recent_done

        cond do
          recorded = continuation_declaration(snap) ->
            case ImportInterview.check(recorded, cumulative, done) do
              :ok ->
                {:cont, acc}

              :excluded_completed ->
                {:halt, exclusion_gate(params, target, snap, recorded, adds, done)}

              {:refuse, message} ->
                {:halt, {:refuse, message}}
            end

          ImportInterview.first_import?(snap.live, cumulative) ->
            {:halt, first_import(params, target, snap, adds, cumulative, done, gate)}

          true ->
            {:cont, acc}
        end
      end)
    else
      {:ok, nil}
    end
  end

  # A recorded declaration binds while its import is still live — the window
  # still carries adds. A quiet window means the import is history: later
  # mid-work batches are not bound by it.
  defp continuation_declaration(%{recent: recent, declaration: declaration}) do
    if recent > 0, do: ImportInterview.from_consult(declaration)
  end

  # First-import scope: the declaration params decide. Absent, the demand
  # refusal teaches the re-call — unless the account's ceremony off-switch
  # (2.8.9, learned on the by-hash consult) says the operator doesn't want
  # their skilled agents stopped, in which case the batch flows plain (the
  # facts and riders still ride). Present, the arithmetic decides.
  defp first_import(params, target, snap, adds, cumulative, done, gate) do
    case ImportInterview.from_params(params) do
      :none ->
        case Client.get("/api/v1/import_approvals/#{payload_hash(params.operations)}") do
          {:ok, %{"status" => "skipped"}} ->
            {:ok, nil}

          _any ->
            needs_readback? =
              match?({:gate, _}, gate) and is_nil(presence(Map.get(params, :readback)))

            {:refuse, ImportInterview.demand_message(cumulative, needs_readback?)}
        end

      {:invalid, message} ->
        {:refuse, message}

      {:ok, decl} ->
        case ImportInterview.check(decl, cumulative, done) do
          :ok -> {:ok, %{target: target, declaration: decl, approved?: false}}
          :excluded_completed -> exclusion_gate(params, target, snap, decl, adds, done)
          {:refuse, message} -> {:refuse, message}
        end
    end
  end

  # The declared-exclusion park (m03.04 2.8.10.2 riding 2.8.8's machinery):
  # consult the operator's recorded decision for this exact batch's hash.
  # Approved flows (the record stamps the click); dismissed latches the
  # declined refusal for this payload; a `skipped` answer means the
  # account's ceremony is dormant (2.8.9) — the declaration stands and the
  # batch flows; anything else (re-)parks the import for the operator. The
  # park POST is idempotent server-side, so a retry never duplicates the
  # card.
  defp exclusion_gate(params, target, snap, decl, adds, done) do
    accepted = %{target: target, declaration: decl, approved?: false}

    case Client.get("/api/v1/import_approvals/#{payload_hash(params.operations)}") do
      {:ok, %{"status" => "skipped"}} ->
        {:ok, accepted}

      {:ok, %{"status" => "approved"}} ->
        {:ok, %{accepted | approved?: true}}

      {:ok, %{"status" => "dismissed"} = row} ->
        {:refuse, ImportInterview.declined_message(row["decision_reason"])}

      _pending_or_none ->
        park_exclusion(params, target, snap, decl, adds, done)
    end
  end

  # Park the import on the operator's account and hand the agent the
  # operator-facing approve URL. A failed park never misstates: the message
  # then says the park didn't land and a re-send retries it.
  defp park_exclusion(params, target, snap, decl, adds, done) do
    body = %{
      payload_hash: payload_hash(params.operations),
      task_count: adds,
      initiative_name: park_name(target, snap, params.operations),
      sample: BatchShape.deep_sample(params.operations)
    }

    message = ImportInterview.parked_message(decl, done)

    case Client.post("/api/v1/import_approvals", body) do
      {:ok, %{"url" => url}} ->
        {:refuse, message, %{approve_url: url}}

      failure ->
        Logger.warning("import declaration park failed: #{inspect(failure)}")
        park_failed(message)
    end
  end

  # The park's card name: a bootstrap batch names its own Initiative add; an
  # existing target's name rides the snapshot.
  defp park_name({:in_batch, _lid}, _snap, operations),
    do: BatchShape.first_initiative_name(operations)

  defp park_name(_target, %{name: name}, _operations) when is_binary(name), do: name
  defp park_name(_target, _snap, operations), do: BatchShape.first_initiative_name(operations)

  # The portable identity binding an approval to the exact batch — sha256
  # hex over the operations, computed exactly as pinned (the idempotency
  # precedent): a changed batch parks fresh, an unchanged one resolves.
  defp payload_hash(operations) do
    :crypto.hash(:sha256, :erlang.term_to_binary(operations, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp shape_refused(message, extra \\ %{}) do
    payload =
      Map.merge(%{ok: false, applied: false, gate: "batch_shape", message: message}, extra)

    response = Response.json(Response.tool(), payload)
    %{response | isError: true}
  end

  defp readback_refused(message) do
    payload = %{ok: false, applied: false, gate: "import_readback", message: message}
    response = Response.json(Response.tool(), payload)
    %{response | isError: true}
  end

  defp interview_refused(message, extra \\ %{}) do
    payload =
      Map.merge(%{ok: false, applied: false, gate: "import_declaration", message: message}, extra)

    response = Response.json(Response.tool(), payload)
    %{response | isError: true}
  end

  # Whether this apply must carry the import's record (m03.04 2.8.4.1): an
  # import-shaped batch (the classifier fired), an operator-confirmed shape
  # override, or an accepted first-import declaration (2.8.10). The
  # declaration IS the first import's record — no prose readback demanded
  # when it covers the flagged target (a shape override still needs its
  # attestation prose). The record's home is the classifier's target; an
  # override under the threshold homes on the batch's first target
  # Initiative.
  defp record_demand(gate, shape, params, parent_targets, interview) do
    cond do
      gate == :pass and shape == :pass and is_nil(interview) ->
        :none

      interview_covers?(interview, gate, shape) ->
        {:record,
         %{
           target: interview.target,
           message: record_message(params, interview.target, interview, shape)
         }}

      is_nil(presence(Map.get(params, :readback))) ->
        {:missing_readback, readback_required_message(gate, shape)}

      true ->
        target =
          case gate do
            {:gate, info} ->
              info.target

            :pass ->
              (interview && interview.target) ||
                List.first(ImportGate.target_refs(params.operations, parent_targets))
          end

        {:record, %{target: target, message: record_message(params, target, interview, shape)}}
    end
  end

  defp interview_covers?(nil, _gate, _shape), do: false
  defp interview_covers?(_interview, _gate, shape) when shape != :pass, do: false
  defp interview_covers?(_interview, :pass, _shape), do: true

  defp interview_covers?(interview, {:gate, %{target: target}}, _shape),
    do: target == interview.target

  defp readback_required_message({:gate, %{task_adds: task_adds, cumulative: cumulative}}, _shape) do
    "Import readback required — nothing was applied; no operator step is needed. This batch adds #{task_adds} tasks (#{cumulative} cumulative in the trailing window). Re-call `apply_operations` with the same operations plus `readback`: one paragraph stating the source scope, task hierarchy and grain, and treatment of completed or excluded items. Use `assumptions` only for agent-made decisions and `settled` only for explicit operator instructions, with one decision per string. The batch then applies, posts the record as a provenance comment on the target Initiative's root task, and settles later chunks for this session."
  end

  defp readback_required_message(:pass, _shape) do
    "Approved-content readback required — nothing was applied. The operator approved this exact batch, but its import record is missing. Re-call `apply_operations` with the same operations unchanged plus `readback` describing the approved content. The server posts the record as a provenance comment on the target Initiative's root task, stamped operator-approved."
  end

  # Resolve the batch's parent-anchored task-adds (`parent_id` = an existing
  # task) to their Initiatives — one GET /api/v1/tasks/:id per unique parent
  # (m03.04 2.8.1) — for the classifier's per-target counting. Skipped
  # when the classifier could never fire (kill switch off). A parent the read
  # can't resolve (404/error) is left out of the map: its adds keep the old
  # dropped behavior and the apply surfaces the real error.
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

  defp apply_batch(params, frame, parent_targets, opts) do
    result =
      Client.operations(params.operations, idempotency_key: Map.get(params, :idempotency_key))

    {:reply, response, frame} = ToolResult.reply_batch(frame, result)

    response =
      case result do
        {:ok, body} ->
          # Pressure lives in the DATABASE (inserted_at window) — applied
          # adds count themselves. Only the session's readback record needs
          # carrying: recorded under a fresh Initiative's lid, later chunks
          # reference the real id (carry_records reads the settle below).
          record = opts[:record]
          flavored? = Keyword.get(opts, :import_flavored, false)
          if record, do: settle_record(record.target)
          created = carry_records(params.operations, body)
          if interview = opts[:interview], do: record_declaration(interview, created)

          response
          |> post_record(record, body)
          |> note_open_only(params.operations, flavored?)
          |> suggest_marker(params.operations, created, parent_targets, flavored?)

        _ ->
          response
      end

    {:reply, response, frame}
  end

  # One record settles the Initiative for the session (m03.04 2.8.4.1) —
  # later chunks flow without re-asking; create_task's singles pause reads
  # the same memory.
  defp settle_record(nil), do: :ok
  defp settle_record(target), do: Counter.mark_confirmed(target)

  # Record the accepted declaration Initiative-homed (m03.04 2.8.10.4) — the
  # server-side, TTL-free row every later chunk is checked against.
  # Idempotent server-side (the first declaration binds); a failed post only
  # logs — the next chunk re-demands if the row never landed.
  defp record_declaration(%{target: target, declaration: decl}, created) do
    id =
      case target do
        {:existing, id} -> id
        {:in_batch, lid} -> created[lid]
      end

    with false <- is_nil(id),
         {:ok, _} <-
           Client.post("/api/v1/import_declarations", ImportInterview.record_attrs(decl, id)) do
      :ok
    else
      failure -> Logger.warning("import declaration record failed: #{inspect(failure)}")
    end
  end

  defp carry_records(operations, body) do
    results = (is_map(body) && Map.get(body, "results")) || []
    created = ImportGate.created_initiative_ids(operations, results)

    Enum.each(created, fn {lid, id} ->
      if Counter.confirmed?({:in_batch, lid}), do: Counter.mark_confirmed({:existing, id})
    end)

    created
  end

  # Post the import's record — the composed readback — as a provenance
  # comment on the target Initiative's root task (m03.04 2.8.4.1).
  # Root-thread comments may run long by design (m03.04 2.4.3), so the record
  # is exempt from the long-comment lint by home. A failure never unwinds
  # the applied batch — the response asks the agent to post the record
  # itself.
  defp post_record(response, nil, _body), do: response

  defp post_record(response, record, body) do
    with root when is_integer(root) <- record_root(record.target, body),
         comment = %{"task_id" => root, "body" => record.message},
         {:ok, _} <- Client.operations([%{"op" => "add", "type" => "comment", "data" => comment}]) do
      Response.text(response, @record_note)
    else
      failure ->
        Logger.warning("import readback record post failed: #{inspect(failure)}")
        Response.text(response, @record_fallback <> "\n\n" <> record.message)
    end
  end

  # The record's home: the target Initiative's root task. An Initiative
  # created in THIS batch echoes its `root_task_id` in the apply response's
  # per-op data; an existing one is looked up on the initiative list (the
  # markers_for precedent — summaries carry `root_task_id`).
  defp record_root({:in_batch, lid}, body) do
    results = (is_map(body) && Map.get(body, "results")) || []

    Enum.find_value(results, fn
      %{"lid" => ^lid, "status" => "ok", "data" => %{"root_task_id" => root}}
      when is_integer(root) ->
        root

      _ ->
        nil
    end)
  end

  defp record_root({:existing, id}, _body) do
    case Client.get("/api/v1/initiatives") do
      {:ok, summaries} when is_list(summaries) ->
        Enum.find_value(summaries, fn
          %{"id" => ^id, "root_task_id" => root} when is_integer(root) -> root
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  defp record_root(nil, _body), do: nil

  defp record_message(params, target, interview, shape) do
    compose_record(
      presence(Map.get(params, :readback)),
      BatchShape.facts_block(params.operations),
      target_style_line(target),
      Map.get(params, :assumptions) || [],
      Map.get(params, :settled) || [],
      record_stamp(interview, shape),
      interview && ImportInterview.declaration_block(interview.declaration)
    )
  end

  # The record's provenance stamp — one sentence, one mechanism (m03.04
  # 2.8.5.3): every override is the operator's own server-verified click,
  # whether it cleared a declared exclusion (2.8.10) or a shape refusal.
  defp record_stamp(interview, shape) do
    if (interview && interview.approved?) || shape == :approved do
      "Operator-approved in the app."
    end
  end

  # The import's record: the agent's readback first (an accepted declaration
  # leads instead when there is none — the declaration IS the first import's
  # record), then the dimensions the operator's ask settled, the agent's
  # assumptions, the server's shape facts that check them with the verbatim
  # declaration beside them (2.8.10.4); the operator's override stamps last.
  # Nil sections drop.
  defp compose_record(readback, shape_facts, target_style, assumptions, settled, stamp, decl) do
    prefix = if readback, do: @record_prefix, else: @declaration_prefix

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

    [prefix, readback, settled_block, assumptions_block, shape_facts, decl, target_style, stamp]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # An EXISTING target's index_style, printed beneath the shape facts so the
  # record shows how the imported tree renders there. One read per RECORDED
  # import only. A failed read or a response without the key drops the line
  # (fail-open, ImportPressure's precedent); an in-batch target's style is
  # already a shape fact.
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

  # The success riders' import-flavor predicate (m03.04 2.8.7), independent
  # of the pressure gate — the second open-only drive proved a sub-gate
  # import gets no rider at all when everything keys on the gate's 32+
  # scale. Import-flavored: the gate fired, OR the batch bootstraps an
  # Initiative at import scale (an initiative add plus
  # `BatchShape.import_floor/0`+ task-adds), OR that many task-adds land in
  # EXISTING trees. Record/settle stay gate-driven; the marker suggestion
  # and open-only guidance ride this.
  defp import_flavored?({:gate, _info}, _operations, _parent_targets), do: true

  defp import_flavored?(:pass, operations, parent_targets) do
    floor = BatchShape.import_floor()

    ImportGate.count_task_adds(operations) >= floor and
      (Enum.any?(operations, &initiative_add?/1) or
         existing_tree_adds(operations, parent_targets) >= floor)
  end

  defp initiative_add?(%{"op" => "add", "type" => "initiative"}), do: true
  defp initiative_add?(_), do: false

  # Task-adds landing in an EXISTING tree: resolved targets (initiative_id
  # direct, or parent-anchored through the caller's map — in-batch chains
  # included) plus parent-anchored adds the map couldn't resolve (kill
  # switch off, failed read) — the FLOOR decides flavor, so no resolution
  # is required and the riders stay kill-switch-independent.
  defp existing_tree_adds(operations, parent_targets) do
    resolved =
      operations
      |> ImportGate.count_by_target(parent_targets)
      |> Enum.reduce(0, fn
        {{:existing, _id}, n}, acc -> acc + n
        _, acc -> acc
      end)

    resolved + Enum.count(operations, &unresolved_parent_add?(&1, parent_targets))
  end

  defp unresolved_parent_add?(%{"op" => "add", "type" => "task", "data" => data}, parent_targets)
       when is_map(data) do
    not is_binary(data["initiative_lid"]) and is_nil(data["initiative_id"]) and
      not is_binary(data["parent_lid"]) and not is_nil(data["parent_id"]) and
      not Map.has_key?(parent_targets, data["parent_id"])
  end

  defp unresolved_parent_add?(_op, _parent_targets), do: false

  # An import-flavored apply whose task-adds all arrive open ends with the
  # scope recovery words (the PLAN.md drive filtered to unchecked items at
  # read time and imported open-only, unasked — roll-up progress read 0%
  # on a misrepresented tree). A BOOTSTRAP open-only batch now refuses in
  # BatchShape (2.8.7), so this guidance's remaining lanes are approved or
  # attested applies and existing-tree open-only imports.
  defp note_open_only(response, _operations, false), do: response

  defp note_open_only(response, operations, true) do
    case BatchShape.open_only_adds(operations) do
      nil ->
        response

      adds ->
        Response.text(
          response,
          "All #{adds} imported tasks arrived open. Never treat your own plan, promise, assumption, or readback as authorization to override the whole-source default. Unless the operator explicitly requested open-only scope, add omitted completed items with `done: true` and mark imported completed items done now; otherwise roll-up progress is wrong. If this corrects a plan you already stated, inform the operator of the change."
        )
    end
  end

  # An import-flavored apply — task-adds resolved to their target
  # Initiatives, the classifier's own resolution reused, never re-derived —
  # ends with the repo-marker suggestion (m03.04 2.1.4.2): the guidance line
  # plus the server-composed marker, read from the initiative list's
  # `repo_marker` field so the wording never forks from the panel. Once per
  # Initiative per session (Counter); the repo-file check and the offer are
  # the agent's. Everyday batches carry no import flavor and stay clean.
  defp suggest_marker(response, _operations, _created, _parent_targets, false), do: response

  defp suggest_marker(response, operations, created, parent_targets, true) do
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

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil
end
