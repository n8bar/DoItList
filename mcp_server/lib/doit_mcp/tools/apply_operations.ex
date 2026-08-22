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

  The import classifier (contract below) counts CUMULATIVE task-adds per
  target Initiative over a trailing time window — chunking doesn't reset it:

    * **The ramp — 32 / 128:** up to 32 task-adds flow on shape alone; the
      leash stretches to 128 while every batch delivers ONE coherent list —
      every add under a single parent, at most 32 adds. Bulk, mixed-parent,
      or oversized batches keep the tight bound and carry the readback
      record.
    * **Description cap — 8000 characters** per task description, enforced
      by the API (a 422): trim the prose and cite the source doc's path in
      a provenance comment — never split the overflow into continuation
      tasks.
    * **Ideal import shape:** the source WHOLE — completed items arrive
      `done: true`, or roll-up progress lies — skeleton first (Initiative +
      top-level parents), then ~32-add chunks of one parent's children, cut
      from the source, each with a provenance comment naming its section;
      rides the ramp, at most the one readback record.

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
  and its first task, created done (`done` completes on add and update
  alike — one op, never an add plus a flip), in one call:

      [
        %{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "New project"}},
        %{"op" => "add", "type" => "task", "lid" => "t1", "data" => %{"initiative_lid" => "i", "title" => "First task", "done" => true}}
      ]

  When the bootstrapped Initiative imports a hierarchical source, set
  `index_style` in its `data` to match the source's numbering scheme when it
  has a usable one (`outline`, `numerical`, `roman`, `alphabetical`); a
  hierarchy with no usable scheme takes `numerical`; a plain non-referenced
  list stays `none` (the default).

  This tool is a pure pass-through — the caller is responsible for building
  each op object correctly per the wire format above; no reshaping happens
  here.

  ## Conditional updates — `expected_version`

  Task and Initiative reads carry an integer `version`. An update op's `data`
  may include `"expected_version" => <that version>` — read, then
  conditionally write: on a stale token the whole batch rolls back (409, per-op
  code `conflict`) and the error carries the current record under `current`;
  re-read from it and reconcile before retrying. Omitted = unconditional.

  ## Safe retries — `idempotency_key`

  Pass an optional `idempotency_key` (any client-chosen string) to make a retry
  safe: it is forwarded as the `Idempotency-Key` header. One key per batch: a
  200 is committed and never re-sent; a lost response (e.g. a timeout) retries
  with the SAME key, which replays the stored response instead of re-applying
  the batch.

  ## Import readback — a record, not a stop (m03.04 2.8.4)

  Operator consent for imports rides the standing agent-access grant the
  operator flipped on the Initiative, so the server never stops an import to
  fetch a human. What an import-shaped batch must carry is a `readback` —
  your one-paragraph statement of the import shape you are building — which
  the apply records as a provenance comment on the target Initiative's root
  task, prefixed as the import's record (root-thread comments may run long
  by design).

  Import-shaped means the classifier's cumulative trigger fired — armed by
  default (`DOITLIST_IMPORT_GATE=off` opts out), per target Initiative over
  a trailing time window: recent task creations are read from the DATABASE
  (`DoitMcp.ImportPressure`, via `GET /initiatives/:id/task_count?created_at=`),
  so chunking can't slip past it, reconnecting can't reset it, and a
  human-rhythm drip of creates decays out on its own. The recent count plus
  the current batch crosses the batch's bound: 32 normally, 128 for a
  coherent one-list batch (every add under one parent, at most 32 adds —
  each such unit lands as one reviewable increment; the ramp). Adds anchored
  on an EXISTING task's `parent_id` count too (m03.04 2.8.1): the
  adapter resolves each unique parent to its Initiative through
  `GET /api/v1/tasks/:id` — one read per unique parent per batch — before
  the classifier runs, so growing an existing tree can't dodge the
  threshold.

  An import-shaped batch WITHOUT a `readback` is refused unapplied — an
  agent-facing refusal, no operator step: re-call with `readback`, plus
  optional `assumptions` (your assumption-tagged decisions, one string
  each) and `settled` (dimensions the operator's own ask already settled —
  an explicit depth, a "summarize" instruction — one string each). WITH a
  readback the batch applies immediately; the composed record (readback,
  settled, assumptions, the server's shape facts) posts as the root
  provenance comment, and one record settles the Initiative for the session
  — later chunks flow without re-asking. A readback recorded under a fresh
  Initiative's lid follows it to the real id the response echoes.

  Shape refusals (file mirror, checklists, boilerplate — each message
  teaches its recovery) are overridable only by the operator's own
  instruction: confirm with them in chat, then re-call with
  `operator_confirmed: true` plus `readback`; the record is stamped
  "Operator-confirmed in chat", so the trail shows the attestation. The
  open-only bootstrap refusal is the exception (m03.04 2.8.8): its override
  is the operator's own click — the refusal parks the import for their
  in-app approval; approved, the SAME batch re-sent flows and its record is
  stamped "Operator-approved in the app"; dismissed, the same payload keeps
  refusing.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias Anubis.Server.Response
  alias DoitMcp.{BatchShape, Client, ImportGate, ImportPressure, ToolResult}
  alias DoitMcp.ImportGate.Counter

  @record_prefix "Import record — readback as applied:"

  @record_note "Import readback recorded as a provenance comment on the target " <>
                 "Initiative's root task."

  @record_fallback "The batch applied, but the readback record could NOT be posted " <>
                     "automatically. Post it yourself: add_comment on the target " <>
                     "Initiative's `root_task_id` with the readback text, prefixed " <>
                     "\"Import record\"."

  @marker_guidance "If the repo's agent-instruction file (CLAUDE.md, AGENTS.md) has no " <>
                     "'## Do It List' marker, offer the operator to add it:"

  schema do
    field(:operations, {:list, :map}, required: true)
    field(:idempotency_key, :string, required: false)
    field(:readback, :string, required: false)
    field(:assumptions, {:list, :string}, required: false)
    field(:settled, {:list, :string}, required: false)
    field(:operator_confirmed, :boolean, required: false)
  end

  def execute(params, frame) do
    # Content-shape pass first (m03.04 3.1 iteration 1): a refusal costs no
    # API reads. Rides the classifier's kill switch — one switch disarms all
    # import guardrails.
    case shape_check(params) do
      {:refuse, message} ->
        {:reply, shape_refused(message), frame}

      {:refuse, message, extra} ->
        {:reply, shape_refused(message, extra), frame}

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
            parent_targets: parent_targets
          )

        flavored? = import_flavored?(gate, params.operations, parent_targets)

        case record_demand(gate, shape, params, parent_targets) do
          :none ->
            apply_batch(params, frame, parent_targets, import_flavored: flavored?)

          {:missing_readback, message} ->
            {:reply, readback_refused(message), frame}

          {:record, record} ->
            apply_batch(params, frame, parent_targets,
              record: record,
              import_flavored: flavored?
            )
        end
    end
  end

  # BatchShape verdict folded with the operator-confirmed override (m03.04
  # item 36.2): a refusal stands unless the agent attests the operator asked
  # for this exact shape in chat (`operator_confirmed: true`); the override
  # demands a readback, and the record is stamped so the trail shows the
  # attestation. The open-only bootstrap refusal is the exception (2.8.8):
  # attestation doesn't move it — its override is the operator's own click,
  # consulted server-side.
  defp shape_check(params) do
    if ImportGate.enabled?() do
      case BatchShape.classify(params.operations) do
        {:refuse, message} ->
          if operator_confirmed?(params), do: :overridden, else: {:refuse, message}

        {:refuse_open_only, info} ->
          open_only_check(params, info)

        :pass ->
          :pass
      end
    else
      :pass
    end
  end

  # The open-only override is server-VERIFIED (m03.04 2.8.8): consult the
  # operator's recorded decision for this exact batch's hash. Approved flows
  # (the record stamps the approval); dismissed latches the declined refusal
  # for this payload; anything else — pending, nothing yet, an expired park
  # — (re-)parks the import for the operator and refuses with both recovery
  # lanes. The park POST is idempotent server-side, so a retry never
  # duplicates the card. This consult is the ceremony's one entry point
  # adapter-side, so the operator's account-level off-switch rides the same
  # read (2.8.9): a `skipped` answer means the ceremony is dormant for this
  # account — the batch applies as a plain pass (no park, no stop) while the
  # open-only facts and guidance still ride, since they key on the batch's
  # shape, never on the ceremony.
  defp open_only_check(params, info) do
    case Client.get("/api/v1/import_approvals/#{payload_hash(params.operations)}") do
      {:ok, %{"status" => "skipped"}} ->
        :pass

      {:ok, %{"status" => "approved"}} ->
        :approved

      {:ok, %{"status" => "dismissed"}} ->
        {:refuse, BatchShape.open_only_declined_message(info)}

      _pending_or_none ->
        park_open_only(params, info)
    end
  end

  # Park the refused import on the operator's account (their Initiative
  # doesn't exist yet) and hand the agent the operator-facing approve URL. A
  # failed park never misstates: the message then says the park didn't land
  # and a re-send retries it.
  defp park_open_only(params, info) do
    body = %{
      payload_hash: payload_hash(params.operations),
      task_count: info.adds,
      initiative_name: info.initiative_name
    }

    message = BatchShape.open_only_message(info)

    case Client.post("/api/v1/import_approvals", body) do
      {:ok, %{"url" => url}} ->
        {:refuse, message, %{approve_url: url}}

      failure ->
        Logger.warning("open-only import approval park failed: #{inspect(failure)}")

        {:refuse,
         message <>
           " (The approval request could not be parked in the app just now — " <>
           "re-sending will park it again.)"}
    end
  end

  # The portable identity binding an approval to the exact batch — sha256
  # hex over the operations, computed exactly as pinned (the idempotency
  # precedent): a changed batch parks fresh, an unchanged one resolves.
  defp payload_hash(operations) do
    :crypto.hash(:sha256, :erlang.term_to_binary(operations, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp operator_confirmed?(params), do: Map.get(params, :operator_confirmed) == true

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

  # Whether this apply must carry the import's record (m03.04 2.8.4.1): an
  # import-shaped batch (the classifier fired), an operator-confirmed shape
  # override, or an operator-approved open-only bootstrap (2.8.8). Either
  # way the readback is required — its absence is an agent-facing refusal
  # teaching the re-call, never a stop for a human. The record's home is the
  # classifier's target; an override under the threshold homes on the
  # batch's first target Initiative.
  defp record_demand(gate, shape, params, parent_targets) do
    cond do
      gate == :pass and shape == :pass ->
        :none

      is_nil(presence(Map.get(params, :readback))) ->
        {:missing_readback, readback_required_message(gate, shape)}

      true ->
        target =
          case gate do
            {:gate, info} -> info.target
            :pass -> List.first(ImportGate.target_refs(params.operations, parent_targets))
          end

        {:record, %{target: target, message: record_message(params, target, shape)}}
    end
  end

  defp readback_required_message({:gate, %{task_adds: task_adds, cumulative: cumulative}}, _shape) do
    "Import readback required: this batch adds #{task_adds} tasks (#{cumulative} this " <>
      "session, chunks included), so it is import-shaped and its record must exist. " <>
      "Nothing was applied; no operator step is needed. Re-call apply_operations with " <>
      "the SAME operations plus `readback` — your one-paragraph statement of the " <>
      "import shape you're building — and optionally `assumptions` (assumption-tagged " <>
      "decisions, one string each) and `settled` (dimensions the operator's own ask " <>
      "already settled, one string each). The batch then applies immediately and the " <>
      "readback lands as a provenance comment on the target Initiative's root task. " <>
      "Alternatively: batches that deliver one list at a time (every add under one " <>
      "parent, at most #{ImportGate.threshold()} adds) flow without a readback up to " <>
      "#{ImportGate.ramp_threshold()} cumulative — chunk the import that way."
  end

  defp readback_required_message(:pass, :approved) do
    "Import record required: the operator approved this import in the app, and the " <>
      "approval must land in the import's record. Nothing was applied. Re-call " <>
      "apply_operations with the SAME operations plus `readback` — your one-paragraph " <>
      "statement of the import shape — and the record posts as a provenance comment " <>
      "on the new Initiative's root task, stamped operator-approved."
  end

  defp readback_required_message(:pass, _shape) do
    "Shape override readback required: `operator_confirmed` attests the operator asked " <>
      "for this shape in chat, and the attestation must land in the import's record. " <>
      "Nothing was applied. Re-call apply_operations with the SAME operations plus " <>
      "`readback` — the record posts as a provenance comment on the target " <>
      "Initiative's root task, stamped operator-confirmed."
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
        Response.text(response, @record_fallback)
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

  defp record_message(params, target, shape) do
    compose_record(
      presence(Map.get(params, :readback)),
      BatchShape.facts_block(params.operations),
      target_style_line(target),
      Map.get(params, :assumptions) || [],
      Map.get(params, :settled) || [],
      record_stamp(shape, params)
    )
  end

  # The record's provenance stamp: an operator-approved open-only import
  # (2.8.8) stamps the server-verified click; any other apply with the
  # attestation param stamps the chat confirm.
  defp record_stamp(:approved, _params), do: "Operator-approved in the app."

  defp record_stamp(_shape, params) do
    if operator_confirmed?(params), do: "Operator-confirmed in chat."
  end

  # The import's record: the agent's readback first, then the dimensions the
  # operator's ask settled, the agent's assumptions, and the server's shape
  # facts that check them; the operator's override stamps last. Nil sections
  # drop.
  defp compose_record(readback, shape_facts, target_style, assumptions, settled, stamp) do
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

    [@record_prefix, readback, settled_block, assumptions_block, shape_facts, target_style, stamp]
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
          "All #{adds} imported tasks arrived open. If the source marks items " <>
            "complete, they import as adds with `done: true` (or `update` ops now) — " <>
            "roll-up progress is wrong without them. Narrowing an import to open " <>
            "items only is the operator's call, not a default."
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
