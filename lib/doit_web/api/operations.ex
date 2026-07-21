defmodule DoItWeb.Api.Operations do
  @moduledoc """
  The atomic mutation surface for `/api/v1` (m03.01 worklist 3) — the engine
  behind `POST /api/v1/operations`.

  A single request carries an **ordered list of operations** applied
  **all-or-nothing** in one `Ecto.Multi` transaction (`Repo.transaction/1`).
  Either every op commits or none does. A single-item write is just a batch of
  one. The surface is **reversible-only**: permanent delete, transfer of
  ownership, and account self-management are not reachable here (see
  "Irreversible ops" below).

  Every op is wired over the **existing** domain contexts (`DoIt.Tasks`,
  `DoIt.Initiatives`, `DoIt.Notifications`) — the same functions the LiveView
  calls — so behavior stays identical across UI and API. This module adds no
  domain logic: it parses the wire envelope, resolves references, authorizes,
  delegates, and reports per-op.

  ## Op envelope

  The request body is `{"operations": [<op>, ...]}`. Each `<op>` is:

      {
        "op":   "add" | "update" | "remove",   // the verb
        "type": "task" | "initiative" | "comment" | "member" | "notification" | "link",
        "id":   123,        // target of an update/remove (an EXISTING resource)
        "lid":  "t1",       // on `add`: the client-assigned local id (see below)
                            // on update/remove: a reference to a prior add's lid
        "data": { ... }     // the op's payload (per op, see the table)
      }

  Verbs follow the JSON:API `atomic:operations` pattern: `add` creates, `update`
  mutates, `remove` reversibly deletes/detaches. The *intent within* a verb is
  read from `data` (e.g. a task `update` whose `data` carries `parent_id` is a
  reparent; one carrying `done` is a completion). One op addresses **one
  concern**.

  ### `lid` — batch-local ids and forward references

  An `add` op may carry a string `lid` ("local id"). It is registered to the
  real inserted id and **later ops in the same batch** may reference it:

    * the op's own `lid` field (on a non-add op) targets that created resource;
    * inside `data`, a `<field>_lid` key references it for a relationship —
      e.g. `"parent_lid": "t1"` instead of `"parent_id": 123`, or
      `"initiative_lid": "i1"`.

  Resolution happens **within the transaction**: an accumulating lid → `{id,
  type}` map is rebuilt from the Multi's prior-step results at each step, so a
  reference only resolves to an **earlier** op of the **matching type**. A
  reference to an unknown, forward (later), foreign, or wrong-type lid — or a
  duplicate lid — is a per-op error that rolls the whole batch back. lids are
  batch-local; they never persist and never cross requests.

  ### The wired operation set

  | op       | type           | `data` / discriminator                         | context fn                              | capability        |
  |----------|----------------|------------------------------------------------|-----------------------------------------|-------------------|
  | `add`    | `task`         | `initiative_id`/`initiative_lid`, `parent_id`/`parent_lid`, `title`, `priority`, `assignee_id`, `manual_progress`, `position` | `Tasks.create_task/2`                   | edit              |
  | `update` | `task`         | field edits: `title`/`description`/`priority`/`assignee_id`/`manual_progress` | `Tasks.update_task/3`                    | edit              |
  | `update` | `task`         | `done: true`/`false`                           | `Tasks.cascade_complete/2` / `…incomplete/2` | edit         |
  | `update` | `task`         | `parent_id`/`parent_lid` and/or `position`/`reorder` | `Tasks.move_task/3`                | edit              |
  | `update` | `task`         | `co_assignee_ids: [..]`                         | `Tasks.add/remove/reorder_co_assignee(s)` | edit            |
  | `remove` | `task`         | —                                              | `Tasks.delete_task/2` (soft, undoable)  | edit              |
  | `add`    | `initiative`   | `name`, `subtitle`, `progress_calc`, `index_style`, … | `Initiatives.create_initiative/2`  | (any authed user) |
  | `update` | `initiative`   | content: `name`/`subtitle`/`progress_calc`/`index_style`/… | `Initiatives.update_initiative/2` + `update_subtitle/2` | edit |
  | `update` | `initiative`   | `state: "archived"`/`"unarchived"`/`"hidden"`/`"unhidden"` | `Initiatives.archive/hide…`         | view (own membership) |
  | `update` | `initiative`   | `state: "trashed"`/`"restored"`                | `Initiatives.trash/restore_initiative/1`| admin             |
  | `add`    | `comment`      | `task_id`/`task_lid`, `body`                   | `Tasks.add_comment/3`                   | edit              |
  | `update` | `comment`      | `body`                                         | `Tasks.edit_comment/3` (author-only)    | edit              |
  | `remove` | `comment`      | —                                              | `Tasks.delete_comment/2` (author-only, tombstone) | edit    |
  | `add`    | `member`       | `initiative_id`/`initiative_lid`, `user_id`, `role` | `Initiatives.add_member/4`         | admin             |
  | `update` | `member`       | `initiative_id`/`initiative_lid`, `user_id`, `role` | `Initiatives.update_member_role/4` | admin             |
  | `remove` | `member`       | `initiative_id`/`initiative_lid`, `user_id`    | `Initiatives.remove_member/3`           | admin             |
  | `update` | `notification` | `read: true` (target `id`), or `all: true`     | `Notifications.mark_read/1` / `mark_all_read/1` | own notification |
  | `add`    | `link`         | `source_id`/`source_lid`, `target_id`/`target_lid` | `Tasks.create_link/2`              | edit (source) |
  | `remove` | `link`         | `source_id`/`source_lid`, `target_id`/`target_lid` | `Tasks.remove_link/2`              | edit (source) |

  ### Task parentage (and one-batch bootstrap)

  An `add task` resolves both an Initiative and a parent. Give a `parent_id` /
  `parent_lid` (the parent may be a `lid` created earlier in the batch) and the
  Initiative is derived from it. Give an `initiative_id` / `initiative_lid` with
  **no** parent and the task is created **top-level**: its parent defaults to
  that Initiative's root task. This is what lets a single batch create an
  Initiative (`lid`) and its first top-level task referencing it via
  `initiative_lid` — no two-round-trip bootstrap, and the caller never needs the
  Initiative's `root_task_id` (which isn't referenceable as a `parent_lid` for a
  just-created Initiative). The default parent goes through the same `:edit`
  authz and same-Initiative parent guard as any explicit parent.

  ### Cross-references (`link`, worklist 4)

  A `link` is a task→task cross-reference ("see that other task"), anchored on
  the two **stable** task ids so it survives reorder/reparent; the read surface
  resolves it to the target's **live** index label (worklist 4.3). A link is
  identified by its `(source, target)` **pair** (not a single `id`/`lid` target),
  so both `add` and `remove` carry the pair in `data`. Either endpoint may be a
  batch-local `*_lid` — so one batch can create two tasks and link them.

    * `add link` dedupes on the unique `(source, target)` index — re-adding the
      same pair is an `unprocessable_entity` per-op error (the batch rolls back).
    * `remove link` is by pair; removing a link that doesn't exist is a clean
      `not_found` per-op error (it rolls the batch back — mirrors `remove member`).
    * **Same-Initiative only.** Both endpoints must belong to the same
      Initiative; the acting user needs **edit** on it (which subsumes view of the
      target). A target in another Initiative — or a foreign task the caller can't
      reach — is rejected, the analogue of the `parent_id` same-Initiative guard.
      Both endpoints must be **live** (a soft-deleted/Trashed endpoint → `not_found`).

  Per-op **authorization** (no privilege escalation — the token only identifies
  the user): the affected Initiative is resolved for each op and the acting user
  is checked through the **existing** role predicates (`DoItWeb.Api.Authz` over
  `Initiatives.can_view?/can_edit?/can_admin?`). edit gates content ops
  (task/comment/Initiative content, and cross-reference `link` add/remove on the
  source's Initiative); admin gates membership/role + the global
  lifecycle (Trash); view gates the per-user lifecycle (archive/hide, which only
  ever touch the caller's own membership row); a notification op authorizes by
  ownership. A single unauthorized op fails the **whole** batch.

  **Agent access** (m03.04 item 2.12.2): every per-op authorize runs through
  `Authz.fetch_initiative/3`, so an op targeting an Initiative with agent access
  **off** fails `not_found` before any work — masked to the op's own target
  shape (a task/comment inside it reads as "no such task/comment"), so the
  response never confirms a flagged-off Initiative or its contents exist.

  ## Irreversible ops — rejected

  Permanent delete / empty-Trash, transfer of ownership, and account
  self-management are intentionally **not reachable** (Q6 — they stay
  LiveView-only). They are rejected as a per-op error before any write:

    * `remove initiative` → `irreversible_op` (Trash is the reversible
      `update initiative {state: "trashed"}`; there is no permanent-delete verb).
    * an `update initiative` `data` carrying `owner_id` → `irreversible_op`
      (transfer of ownership). Initiative-content updates are field-whitelisted,
      so no privileged column can be set through the generic changeset.
    * an `add`/`update member` `data` carrying `role: "owner"` →
      `irreversible_op` (minting an owner bypasses the guarded transfer flow and
      can leave multiple owners — `role` is limited to `editor`/`viewer`).
    * any `type` outside the set above (e.g. `user`/`account`) → `unsupported_op`.

  ## Response shapes

  Success (HTTP 200) echoes each op's outcome in order, including the lid → id
  mapping for creates:

      {"results": [
        {"index": 0, "lid": "t1", "status": "ok", "data": {"id": 100, "type": "task", ...}},
        {"index": 1, "status": "ok", "data": {"id": 101, "type": "task", ...}}
      ]}

  Any failure rolls the whole batch back (nothing applied) and identifies the
  **offending op by index** with the per-op error shape pinned in `DoItWeb.Api`
  (`code`, `message`, optional `pointer`); every other op is marked
  `not_applied`. HTTP status is **403** when the offending op failed
  authorization, otherwise **422**:

      {
        "error": {"status": 422, "code": "unprocessable_entity",
                  "message": "Operation at index 1 failed; the batch was rolled back."},
        "results": [
          {"index": 0, "lid": "t1", "status": "not_applied"},
          {"index": 1, "status": "error",
           "error": {"code": "unprocessable_entity", "message": "title can't be blank", "pointer": "title"}}
        ]
      }

  Per-op `code` vocabulary: `unprocessable_entity` (validation / a domain
  rejection), `forbidden` (authz / author-only), `not_found` (a target or
  referenced resource is missing), `bad_reference` (a bad/forward/foreign/
  duplicate lid), `unsupported_op` (unknown verb/type/combination),
  `irreversible_op` (a rejected irreversible op).
  """

  import Ecto.Query, only: [from: 2]

  alias DoIt.{Broadcast, Initiatives, Notifications, Repo, Tasks}
  alias DoIt.Accounts.User
  alias DoIt.Initiatives.Initiative
  alias DoIt.Notifications.Notification
  alias DoIt.Tasks.{Comment, Task}
  alias DoItWeb.Api.Authz

  @types ~w(task initiative comment member notification link)
  @verbs ~w(add update remove)

  # Hard cap on ops per batch, enforced before any DB work (see apply_batch/2).
  # The whole batch runs in one synchronous Repo.transaction, which is bound by
  # the 15 s transaction timeout — breach it and the entire batch fails. A
  # cascade-heavy benchmark (dev-over-docker) ran roughly linear at ~40-55 ms/op;
  # 250 ops took ~11 s and 200 breached 15 s once under added load. 150 ops
  # (~6-8 s in that pessimistic env, far less in prod) keeps ~2x headroom while
  # staying a useful atomic batch.
  @max_batch_size 150

  # Initiative-content fields an `update initiative` may set (owner_id and any
  # other column are intentionally excluded — see "Irreversible ops").
  @initiative_content_fields ~w(name description progress_calc index_style ai_knobs auto_promote_co_assignees viewer_plus)

  # The `data` keys each wired {verb, type} accepts, derived from every dispatch
  # path. Drives validate_data_keys/3 — the fail-fast targeted-hint check that
  # rejects an unrecognized key with a per-op error instead of silently dropping
  # it (Map.take only lifts known keys). A {verb, type} that is NOT a key here is
  # left to the unsupported/irreversible dispatch (e.g. remove initiative, add
  # notification, update link) so its own error is never preempted.
  @accepted_data_keys %{
    {"add", "task"} =>
      ~w(initiative_id initiative_lid initiative parent_id parent_lid parent title description priority assignee_id manual_progress position status),
    {"update", "task"} =>
      ~w(parent_id parent_lid parent position reorder done co_assignee_ids title description priority assignee_id manual_progress),
    {"remove", "task"} => [],
    {"add", "initiative"} => @initiative_content_fields ++ ~w(subtitle),
    {"update", "initiative"} => @initiative_content_fields ++ ~w(subtitle state owner_id),
    {"add", "comment"} => ~w(task_id task_lid task body),
    {"update", "comment"} => ~w(body),
    {"remove", "comment"} => [],
    {"add", "member"} => ~w(initiative_id initiative_lid initiative user_id role),
    {"update", "member"} => ~w(initiative_id initiative_lid initiative user_id role),
    {"remove", "member"} => ~w(initiative_id initiative_lid initiative user_id),
    {"update", "notification"} => ~w(all read),
    {"add", "link"} => ~w(source_id source_lid source target_id target_lid target),
    {"remove", "link"} => ~w(source_id source_lid source target_id target_lid target)
  }

  @typedoc "A per-op error carries the wire code, message, an optional field pointer, and the batch HTTP status it implies."
  @type op_error :: %{
          code: String.t(),
          message: String.t(),
          pointer: String.t() | nil,
          http: 403 | 422
        }

  @doc """
  Apply an ordered list of operation maps (string-keyed, as parsed from JSON) on
  behalf of `user`, all-or-nothing.

  Returns:

    * `{:ok, results}` — the batch committed; `results` is an ordered list of
      per-op success maps (`:index`, optional `:lid`, `:status` `"ok"`, `:data`).
    * `{:error, status, results}` — the batch rolled back; `status` is `403` or
      `422`, `results` carries the offending op (`:status` `"error"`, `:error`)
      and every other op as `"not_applied"`.
    * `{:error, :batch_too_large, message}` — more than `@max_batch_size` ops;
      rejected up front (no DB work) and rendered as the single-error shape.
    * `{:error, :invalid_request}` — the body was not a non-empty operations list
      (rendered by the controller as the single-error shape).
  """
  @spec apply_batch(User.t(), list()) ::
          {:ok, [map()]}
          | {:error, 403 | 422, [map()], map()}
          | {:error, :batch_too_large, String.t()}
          | {:error, :invalid_request}
  def apply_batch(%User{} = user, operations)
      when is_list(operations) and operations != [] do
    # Reject an oversized batch before any DB work — the whole batch shares one
    # synchronous transaction bound by the 15 s timeout (see @max_batch_size).
    count = length(operations)

    if count > @max_batch_size do
      {:error, :batch_too_large,
       "Batch has #{count} operations; the maximum is #{@max_batch_size} per request."}
    else
      apply_within_cap(user, operations, count)
    end
  end

  def apply_batch(_user, _operations), do: {:error, :invalid_request}

  defp apply_within_cap(%User{} = user, operations, count) do
    # Drop any broadcast residue a PRIOR raised request left queued on THIS
    # process. DoIt.Broadcast queues in the process dictionary, and Bandit
    # reuses one connection process across keep-alive requests; without this a
    # batch that raised mid-transaction (rolled back) before reaching flush/1
    # would leave its queued broadcasts behind, to be fired by the next
    # successful apply_batch on the same connection — phantom broadcasts for
    # never-persisted rows.
    #
    # NB: discard/1 wipes the WHOLE per-process queue. That is correct here only
    # because apply_batch owns the entire batch boundary; never call it from
    # inside a nested context that shares this process's queue.
    Broadcast.discard(:ok)

    multi =
      operations
      |> Enum.with_index()
      |> Enum.reduce(Ecto.Multi.new(), fn {op, index}, multi ->
        Ecto.Multi.run(multi, {:op, index}, fn _repo, changes ->
          run_op(user, op, index, changes)
        end)
      end)

    try do
      result = Repo.transaction(multi)
      # Every PubSub message queued by a context fn during the batch (task,
      # member, AND notification broadcasts all route through DoIt.Broadcast)
      # fires now on commit, or is dropped on rollback — the all-or-nothing
      # guarantee extends to PubSub side effects, none escaping a rolled-back
      # batch or leaking pre-commit. Coalesced per batch (item 5.8.2): N per-op
      # task messages would trigger N full tree reloads in every open
      # workspace — O(batch x tree) subscriber work; the coalescer collapses
      # them to per-batch signals with identical converged state.
      Broadcast.flush(transaction_ok?(result), &Tasks.coalesce_task_broadcasts/1)
      render(result, count)
    after
      # An op may RAISE inside the transaction (a DB constraint / Postgrex /
      # Ecto.StaleEntryError / an unmatched context return). Repo.transaction
      # then rolls the DB back AND re-raises, skipping the flush above and
      # leaving the rolled-back batch's broadcasts queued. `after` runs on EVERY
      # exit — commit, clean rollback, or raise — so the queue is dropped
      # unconditionally; the raise still propagates, just with no leaked queue.
      Broadcast.discard(:ok)
    end
  end

  # `Repo.transaction(multi)` returns {:ok, changes} | {:error, name, val, changes}.
  # Reduce to the {:ok, _} | other shape Broadcast.flush/1 expects.
  defp transaction_ok?({:ok, _} = ok), do: ok
  defp transaction_ok?(_), do: :rollback

  # --- Result rendering ------------------------------------------------------

  defp render({:ok, changes}, count) do
    results =
      for index <- 0..(count - 1) do
        %{lid: lid, data: data} = Map.fetch!(changes, {:op, index})

        %{index: index, status: "ok", data: data}
        |> maybe_put_lid(lid)
      end

    {:ok, results}
  end

  defp render({:error, {:op, bad_index}, %{} = err, _changes}, count) do
    results =
      for index <- 0..(count - 1) do
        cond do
          index == bad_index ->
            %{index: index, status: "error", error: wire_error(err)}

          true ->
            %{index: index, status: "not_applied"}
        end
      end

    status = Map.get(err, :http, 422)

    {:error, status, results,
     %{
       status: status,
       code: err.code,
       message:
         "Operation at index #{bad_index} failed; the batch was rolled back. Nothing was applied."
     }}
  end

  defp wire_error(%{code: code, message: message} = err) do
    base = %{code: code, message: message}
    if err[:pointer], do: Map.put(base, :pointer, err[:pointer]), else: base
  end

  defp maybe_put_lid(map, nil), do: map
  defp maybe_put_lid(map, lid), do: Map.put(map, :lid, lid)

  # --- Per-op dispatch -------------------------------------------------------

  # Wraps each op so a structured op_error rolls the Multi back at this index,
  # while a normal result is unwrapped into the changes map for later lids.
  defp run_op(user, op, _index, changes) when is_map(op) do
    with {:ok, verb} <- fetch_verb(op),
         {:ok, type} <- fetch_type(op),
         :ok <- validate_data(op),
         :ok <- validate_data_keys(verb, type, data(op)),
         {:ok, result} <- dispatch(user, verb, type, op, changes) do
      {:ok, result}
    else
      {:error, %{} = op_error} -> {:error, op_error}
    end
  end

  defp run_op(_user, _op, _index, _changes),
    do: {:error, err(:unsupported_op, "Each operation must be a JSON object.", 422)}

  # `data` is optional, but when present it MUST be a JSON object. A string or
  # array would raise (Map.take/has_key?/Access) inside a dispatch clause and
  # crash the whole request with a 500 instead of a clean per-op error. Validate
  # the shape up front so every dispatch clause can assume a map.
  defp validate_data(op) do
    case Map.get(op, "data") do
      nil ->
        :ok

      data when is_map(data) ->
        :ok

      _ ->
        {:error,
         err(
           :unprocessable_entity,
           "\"data\" must be a JSON object (got #{inspect(Map.get(op, "data"))}).",
           422,
           "data"
         )}
    end
  end

  # Fail-fast targeted hints for an unrecognized `data` key — across ALL wired
  # ops. Previously most ops SILENTLY DROPPED any key they didn't take (Map.take
  # lifts only known keys) and `update task` returned an opaque generic error;
  # now, before dispatch, we reject the FIRST unknown key with a per-op error
  # naming the likely fix. A {verb, type} absent from @accepted_data_keys is
  # skipped (returns :ok) so combos owned by the unsupported/irreversible
  # dispatch (remove initiative, add notification, update link, …) keep their own
  # errors and aren't preempted here.
  defp validate_data_keys(verb, type, data) do
    case Map.fetch(@accepted_data_keys, {verb, type}) do
      :error ->
        :ok

      {:ok, accepted} ->
        case Map.keys(data) -- accepted do
          [] -> :ok
          [key | _] -> {:error, unknown_field_error(verb, type, key, accepted)}
        end
    end
  end

  # Build the targeted per-op error for the first unrecognized `data` key. The
  # message names the bad field and then either lists the op's accepted keys
  # (sorted) or, for an op that takes no data (remove task/comment), says so.
  # Pointer = key.
  defp unknown_field_error(verb, type, key, accepted) do
    message =
      case accepted do
        [] ->
          "Field #{inspect(key)} isn't accepted — the `#{verb} #{type}` op takes no data (it targets by id/lid)."

        _ ->
          "Field #{inspect(key)} isn't accepted by the `#{verb} #{type}` op." <>
            " Accepted data keys: #{accepted |> Enum.sort() |> Enum.join(", ")}."
      end

    err(:unprocessable_entity, message, 422, key)
  end

  defp fetch_verb(%{"op" => verb}) when verb in @verbs, do: {:ok, verb}

  defp fetch_verb(%{"op" => other}),
    do: {:error, err(:unsupported_op, "Unknown op verb #{inspect(other)}.", 422)}

  defp fetch_verb(_),
    do: {:error, err(:unsupported_op, "Operation is missing its \"op\" verb.", 422)}

  defp fetch_type(%{"type" => type}) when type in @types, do: {:ok, type}

  defp fetch_type(%{"type" => other}),
    do: {:error, err(:unsupported_op, "Unsupported type #{inspect(other)}.", 422)}

  defp fetch_type(_),
    do: {:error, err(:unsupported_op, "Operation is missing its \"type\".", 422)}

  # ---- task -----------------------------------------------------------------

  defp dispatch(user, "add", "task", op, changes) do
    data = data(op)

    with {:ok, lid} <- register_lid(op, changes),
         {:ok, initiative_id, parent_id} <- resolve_task_parentage(data, changes),
         {:ok, %Task{} = parent} <- load_task(parent_id),
         :ok <- parent_in_initiative(parent, initiative_id),
         {:ok, initiative} <- authorize(user, initiative_id, :edit),
         :ok <- validate_assignee_membership(initiative.id, data) do
      attrs =
        data
        |> take(~w(title description priority assignee_id manual_progress position status))
        |> Map.put("initiative_id", initiative.id)
        |> Map.put("parent_id", parent_id)

      case Tasks.create_task(user, attrs) do
        {:ok, task} -> ok(lid, task.id, "task", task_result(task))
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp dispatch(user, "update", "task", op, changes) do
    with {:ok, %Task{} = task} <- fetch_task_target(op, changes),
         {:ok, _initiative} <- authorize(user, task.initiative_id, :edit, task_not_found(task.id)) do
      update_task_by_concern(user, task, data(op), changes)
    end
  end

  defp dispatch(user, "remove", "task", op, changes) do
    with {:ok, %Task{} = task} <- fetch_task_target(op, changes),
         {:ok, _initiative} <- authorize(user, task.initiative_id, :edit, task_not_found(task.id)) do
      case Tasks.delete_task(task, user) do
        {:ok, deleted} ->
          ok(nil, deleted.id, "task", Map.put(task_result(deleted), :deleted, true))

        {:error, reason} ->
          {:error, context_error(reason)}
      end
    end
  end

  # ---- initiative -----------------------------------------------------------

  defp dispatch(user, "add", "initiative", op, changes) do
    data = data(op)

    with {:ok, lid} <- register_lid(op, changes) do
      attrs = take(data, @initiative_content_fields)

      # API/MCP-created Initiatives are agent-accessible from birth (m03.04
      # item 2.12.1) — granted server-side by the context, never cast from the
      # op's data (agent_access isn't an accepted key above).
      case Initiatives.create_initiative(user, attrs, agent_access: true) do
        {:ok, initiative} ->
          with :ok <- maybe_set_subtitle(initiative, data) do
            ok(lid, initiative.id, "initiative", initiative_result(initiative))
          end

        {:error, reason} ->
          {:error, context_error(reason)}
      end
    end
  end

  defp dispatch(_user, "remove", "initiative", _op, _changes) do
    {:error,
     err(
       :irreversible_op,
       "Permanently deleting an Initiative is irreversible and not available via the API. Use update {state: \"trashed\"} for the reversible soft delete.",
       422
     )}
  end

  defp dispatch(user, "update", "initiative", op, changes) do
    data = data(op)

    cond do
      Map.has_key?(data, "owner_id") ->
        {:error,
         err(
           :irreversible_op,
           "Transferring Initiative ownership is irreversible and not available via the API.",
           422
         )}

      Map.has_key?(data, "state") ->
        update_initiative_state(user, op, data["state"], changes)

      true ->
        update_initiative_content(user, op, data, changes)
    end
  end

  # ---- comment --------------------------------------------------------------

  defp dispatch(user, "add", "comment", op, changes) do
    data = data(op)

    with {:ok, lid} <- register_lid(op, changes),
         {:ok, task_id} <- resolve_ref_field(data, "task", changes, "task", required: true),
         {:ok, %Task{} = task} <- load_task(task_id),
         {:ok, _initiative} <- authorize(user, task.initiative_id, :edit, task_not_found(task.id)) do
      case Tasks.add_comment(task, user, data["body"]) do
        {:ok, comment} -> ok(lid, comment.id, "comment", comment_result(comment))
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp dispatch(user, "update", "comment", op, changes) do
    with {:ok, %Comment{} = comment} <- fetch_comment_target(op, changes),
         {:ok, _initiative} <- authorize_comment(user, comment, :edit) do
      case Tasks.edit_comment(comment.id, user, data(op)["body"]) do
        {:ok, updated} ->
          ok(nil, updated.id, "comment", comment_result(updated))

        {:error, :not_found} ->
          {:error, err(:not_found, "No such comment with id #{comment.id}.", 422)}

        {:error, reason} ->
          {:error, context_error(reason)}
      end
    end
  end

  defp dispatch(user, "remove", "comment", op, changes) do
    with {:ok, %Comment{} = comment} <- fetch_comment_target(op, changes),
         {:ok, _initiative} <- authorize_comment(user, comment, :edit) do
      case Tasks.delete_comment(comment.id, user) do
        {:ok, deleted} ->
          ok(nil, deleted.id, "comment", comment_result(deleted))

        {:error, :not_found} ->
          {:error, err(:not_found, "No such comment with id #{comment.id}.", 422)}

        {:error, reason} ->
          {:error, context_error(reason)}
      end
    end
  end

  # ---- member ---------------------------------------------------------------

  defp dispatch(user, "add", "member", op, changes) do
    data = data(op)

    with {:ok, initiative_id} <-
           resolve_ref_field(data, "initiative", changes, "initiative", required: true),
         {:ok, initiative} <- authorize(user, initiative_id, :admin),
         {:ok, target_user_id} <- fetch_int(data, "user_id"),
         {:ok, role} <- fetch_role(data) do
      case Initiatives.add_member(initiative.id, target_user_id, role, user) do
        {:ok, _member} ->
          ok(nil, target_user_id, "member", member_result(initiative.id, target_user_id, role))

        {:error, reason} ->
          {:error, context_error(reason)}
      end
    end
  end

  defp dispatch(user, "update", "member", op, changes) do
    data = data(op)

    with {:ok, initiative_id} <-
           resolve_ref_field(data, "initiative", changes, "initiative", required: true),
         {:ok, initiative} <- authorize(user, initiative_id, :admin),
         {:ok, target_user_id} <- fetch_int(data, "user_id"),
         {:ok, role} <- fetch_role(data) do
      case Initiatives.update_member_role(initiative.id, target_user_id, role, user) do
        {:ok, _member} ->
          ok(nil, target_user_id, "member", member_result(initiative.id, target_user_id, role))

        {:error, :not_found} ->
          {:error,
           err(
             :not_found,
             "No such member with user_id #{target_user_id} in Initiative #{initiative.id}.",
             422
           )}

        {:error, reason} ->
          {:error, context_error(reason)}
      end
    end
  end

  defp dispatch(user, "remove", "member", op, changes) do
    data = data(op)

    with {:ok, initiative_id} <-
           resolve_ref_field(data, "initiative", changes, "initiative", required: true),
         {:ok, initiative} <- authorize(user, initiative_id, :admin),
         {:ok, target_user_id} <- fetch_int(data, "user_id") do
      case Initiatives.remove_member(initiative.id, target_user_id, user) do
        {n, _} when n > 0 ->
          ok(nil, target_user_id, "member", %{
            type: "member",
            initiative_id: initiative.id,
            user_id: target_user_id,
            removed: true
          })

        _ ->
          {:error,
           err(
             :not_found,
             "No such member with user_id #{target_user_id} in Initiative #{initiative.id}.",
             422
           )}
      end
    end
  end

  # ---- notification ---------------------------------------------------------

  defp dispatch(user, "update", "notification", op, _changes) do
    data = data(op)

    cond do
      data["all"] == true ->
        count = Notifications.mark_all_read(user)
        ok(nil, nil, "notification", %{type: "notification", marked_read: count, all: true})

      true ->
        with {:ok, id} <- fetch_target_id(op),
             {:ok, %Notification{} = notification} <- load_notification(id),
             :ok <- own_notification(user, notification) do
          case Notifications.mark_read(notification) do
            {:ok, updated} ->
              ok(nil, updated.id, "notification", %{
                type: "notification",
                id: updated.id,
                read: true
              })

            {:error, reason} ->
              {:error, context_error(reason)}
          end
        end
    end
  end

  # ---- link (cross-reference, worklist 4) -----------------------------------

  defp dispatch(user, "add", "link", op, changes) do
    data = data(op)

    with {:ok, lid} <- register_lid(op, changes),
         {:ok, source} <- resolve_link_endpoint(data, "source", changes),
         {:ok, _initiative} <-
           authorize(user, source.initiative_id, :edit, task_not_found(source.id)),
         {:ok, target} <- resolve_link_endpoint(data, "target", changes),
         :ok <- distinct_link_endpoints(source, target),
         :ok <- same_initiative_link(source, target) do
      case Tasks.create_link(source, target) do
        {:ok, link} -> ok(lid, link.id, "link", link_result(link, source, target))
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp dispatch(user, "remove", "link", op, changes) do
    data = data(op)

    with {:ok, source} <- resolve_link_endpoint_any(data, "source", changes),
         {:ok, _initiative} <-
           authorize(user, source.initiative_id, :edit, task_not_found(source.id)),
         {:ok, target} <- resolve_link_endpoint_any(data, "target", changes) do
      case Tasks.remove_link(source, target) do
        {:ok, link} ->
          ok(nil, link.id, "link", Map.put(link_result(link, source, target), :removed, true))

        {:error, :not_found} ->
          {:error,
           err(
             :not_found,
             "No such cross-reference from task #{source.id} to task #{target.id}.",
             422
           )}
      end
    end
  end

  # ---- unsupported combinations --------------------------------------------

  defp dispatch(_user, verb, type, _op, _changes) do
    {:error, err(:unsupported_op, "Unsupported operation: #{verb} #{type}.", 422)}
  end

  # A link endpoint (`source`/`target`) resolves a `<base>_lid` (a task created
  # earlier in the batch), `<base>_id`, or bare `<base>` to a LIVE task.
  defp resolve_link_endpoint(data, base, changes) do
    with {:ok, id} <- resolve_ref_field(data, base, changes, "task", required: true) do
      case load_task(id) do
        {:ok, task} -> {:ok, task}
        {:error, _} = error -> error
      end
    end
  end

  # Like resolve_link_endpoint/3, but TOLERATES a soft-deleted (Trashed) endpoint.
  # Removing a link is cleanup, so a link whose source or target was since trashed
  # must still be detachable — load the task by id regardless of `deleted_at`.
  defp resolve_link_endpoint_any(data, base, changes) do
    with {:ok, id} <- resolve_ref_field(data, base, changes, "task", required: true) do
      case load_task_any(id) do
        {:ok, task} -> {:ok, task}
        {:error, _} = error -> error
      end
    end
  end

  # A task can't cross-reference itself: reject a self-link (source == target) as
  # a clean per-op error instead of persisting a meaningless self-loop.
  defp distinct_link_endpoints(%Task{id: id}, %Task{id: id}),
    do:
      {:error,
       err(
         :unprocessable_entity,
         "Task #{id} can't cross-reference itself.",
         422,
         "target_id"
       )}

  defp distinct_link_endpoints(_source, _target), do: :ok

  # Cross-references are same-Initiative only (worklist 4.2): authorizing :edit
  # on the source's Initiative then requiring the target in that SAME Initiative
  # collapses "edit source + view target" into one check and keeps the read
  # render free of any cross-Initiative tree load. A foreign/other-Initiative
  # target is rejected here — the analogue of the parent_id same-Initiative guard.
  defp same_initiative_link(%Task{initiative_id: id}, %Task{initiative_id: id}), do: :ok

  defp same_initiative_link(source, target),
    do:
      {:error,
       err(
         :unprocessable_entity,
         "Task #{target.id} belongs to Initiative #{target.initiative_id}, not Initiative #{source.initiative_id} — a cross-reference can't span Initiatives.",
         422,
         "target_id"
       )}

  # --- task update: dispatch by concern --------------------------------------

  defp update_task_by_concern(user, task, data, changes) do
    structural? = Enum.any?(~w(parent_id parent_lid position reorder), &Map.has_key?(data, &1))
    done? = Map.has_key?(data, "done")
    co? = Map.has_key?(data, "co_assignee_ids")
    field_keys = ~w(title description priority assignee_id manual_progress)
    fields? = Enum.any?(field_keys, &Map.has_key?(data, &1))

    case Enum.count([structural?, done?, co?, fields?], & &1) do
      0 ->
        {:error,
         err(
           :unprocessable_entity,
           "A task update must carry at least one of: field edits, done, a move, or co_assignee_ids.",
           422
         )}

      1 ->
        cond do
          structural? -> move_task_op(user, task, data, changes)
          done? -> complete_task_op(user, task, data)
          co? -> co_assignee_op(user, task, data)
          fields? -> update_task_fields(user, task, data)
        end

      _ ->
        {:error,
         err(
           :unprocessable_entity,
           "A task update addresses one concern at a time (field edits, done, a move, or co_assignee_ids) — split them into separate ops.",
           422
         )}
    end
  end

  defp update_task_fields(user, task, data) do
    with :ok <- validate_assignee_membership(task.initiative_id, data) do
      attrs = take(data, ~w(title description priority assignee_id manual_progress))

      case Tasks.update_task(task, user, attrs) do
        {:ok, updated} -> ok(nil, updated.id, "task", task_result(updated))
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp complete_task_op(user, task, %{"done" => done}) do
    cond do
      done == true ->
        case Tasks.cascade_complete(task, user) do
          {:ok, updated} -> ok(nil, updated.id, "task", task_result(updated))
          {:error, reason} -> {:error, context_error(reason)}
        end

      done == false ->
        case Tasks.cascade_incomplete(task, user) do
          {:ok, updated} -> ok(nil, updated.id, "task", task_result(updated))
          {:error, reason} -> {:error, context_error(reason)}
        end

      true ->
        {:error, err(:unprocessable_entity, "\"done\" must be true or false.", 422, "done")}
    end
  end

  defp move_task_op(user, task, data, changes) do
    with {:ok, parent_id} <- resolve_parent_for_move(task, data, changes) do
      attrs =
        %{"parent_id" => parent_id}
        |> maybe_put("position", normalize_int(data["position"]))
        |> maybe_put("reorder", data["reorder"])

      case Tasks.move_task(task, user, attrs) do
        {:ok, moved} -> ok(nil, moved.id, "task", task_result(moved))
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  # A move op may carry parent (reparent) or just position/reorder (sibling
  # reorder). When neither parent key is present, keep the current parent.
  defp resolve_parent_for_move(task, data, changes) do
    cond do
      Map.has_key?(data, "parent_lid") or Map.has_key?(data, "parent_id") ->
        resolve_ref_field(data, "parent", changes, "task", required: false)

      true ->
        {:ok, task.parent_id}
    end
  end

  defp co_assignee_op(user, task, %{"co_assignee_ids" => ids}) when is_list(ids) do
    desired = ids |> Enum.map(&normalize_int/1) |> Enum.reject(&is_nil/1)

    with :ok <- validate_co_assignee_membership(task.initiative_id, desired) do
      current = task.id |> Tasks.list_co_assignees() |> Enum.map(& &1.user_id)

      to_add = desired -- current
      to_remove = current -- desired

      with :ok <- co_add_all(task, user, to_add),
           :ok <- co_remove_all(task, user, to_remove),
           {:ok, _} <- Tasks.reorder_co_assignees(task, user, desired) do
        ok(nil, task.id, "task", Map.put(task_result(task), :co_assignee_ids, desired))
      else
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp co_assignee_op(_user, _task, _data),
    do:
      {:error,
       err(
         :unprocessable_entity,
         "co_assignee_ids must be a list of user ids.",
         422,
         "co_assignee_ids"
       )}

  defp co_add_all(task, user, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Tasks.add_co_assignee(task, user, id) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp co_remove_all(task, user, ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      case Tasks.remove_co_assignee(task, user, id) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # --- initiative update helpers ---------------------------------------------

  defp update_initiative_state(user, op, state, changes) do
    {capability, fun} =
      case state do
        "archived" -> {:view, &Initiatives.archive_initiative/2}
        "unarchived" -> {:view, &Initiatives.unarchive_initiative/2}
        "hidden" -> {:view, &Initiatives.hide_initiative/2}
        "unhidden" -> {:view, &Initiatives.unhide_initiative/2}
        "trashed" -> {:admin, &trash/2}
        "restored" -> {:admin, &restore/2}
        _ -> {nil, nil}
      end

    if is_nil(capability) do
      {:error,
       err(
         :unprocessable_entity,
         "Unknown initiative state #{inspect(state)}. One of: archived, unarchived, hidden, unhidden, trashed, restored.",
         422,
         "state"
       )}
    else
      with {:ok, initiative_id} <- fetch_target_ref(op, changes, "initiative"),
           {:ok, initiative} <- authorize(user, initiative_id, capability) do
        case fun.(user, initiative) do
          {:ok, _} ->
            ok(nil, initiative.id, "initiative", %{
              type: "initiative",
              id: initiative.id,
              state: state
            })

          {:error, reason} ->
            {:error, context_error(reason)}
        end
      end
    end
  end

  # trash/restore ignore the user arg (global lifecycle) so the state dispatch
  # can call every lifecycle fn with a uniform (user, initiative) arity.
  defp trash(_user, initiative), do: Initiatives.trash_initiative(initiative)
  defp restore(_user, initiative), do: Initiatives.restore_initiative(initiative)

  defp update_initiative_content(user, op, data, changes) do
    with {:ok, initiative_id} <- fetch_target_ref(op, changes, "initiative"),
         {:ok, initiative} <- authorize(user, initiative_id, :edit) do
      attrs = take(data, @initiative_content_fields)

      with {:ok, initiative} <- maybe_update_initiative(initiative, attrs),
           :ok <- maybe_set_subtitle(initiative, data) do
        ok(nil, initiative.id, "initiative", initiative_result(reload_initiative(initiative)))
      else
        {:error, reason} -> {:error, context_error(reason)}
      end
    end
  end

  defp maybe_update_initiative(initiative, attrs) when map_size(attrs) == 0, do: {:ok, initiative}

  defp maybe_update_initiative(initiative, attrs),
    do: Initiatives.update_initiative(initiative, attrs)

  defp maybe_set_subtitle(initiative, %{"subtitle" => subtitle}) when is_binary(subtitle) do
    case Initiatives.update_subtitle(initiative, subtitle) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, context_error(reason)}
    end
  end

  defp maybe_set_subtitle(_initiative, _data), do: :ok

  defp reload_initiative(%Initiative{id: id}), do: Initiatives.get_initiative(id)

  # --- reference / lid resolution --------------------------------------------

  # Build the lid → %{id, type} map from the Multi's accumulated prior-step
  # results. Only earlier ops appear (Multi runs in order), so a forward ref
  # never resolves. Creates registered their lid + real id + type.
  defp lid_map(changes) do
    for {{:op, _i}, %{lid: lid, id: id, type: type}} <- changes,
        is_binary(lid),
        into: %{},
        do: {lid, %{id: id, type: type}}
  end

  # On an `add` op, register (and validate the uniqueness of) the op's lid.
  defp register_lid(op, changes) do
    case op["lid"] do
      nil ->
        {:ok, nil}

      lid when is_binary(lid) ->
        if Map.has_key?(lid_map(changes), lid),
          do: {:error, err(:bad_reference, "Duplicate local id #{inspect(lid)}.", 422)},
          else: {:ok, lid}

      _ ->
        {:error,
         err(:bad_reference, "\"lid\" must be a string (got #{inspect(op["lid"])}).", 422)}
    end
  end

  # Resolve a `<base>_lid` (batch-local) or `<base>_id`/`<base>` (literal int)
  # reference inside `data`. `expected_type` is enforced for lid references.
  defp resolve_ref_field(data, base, changes, expected_type, opts) do
    required? = Keyword.get(opts, :required, false)
    lid_key = "#{base}_lid"
    id_key = "#{base}_id"

    cond do
      is_binary(data[lid_key]) ->
        resolve_lid(changes, data[lid_key], expected_type)

      Map.has_key?(data, id_key) ->
        case normalize_int(data[id_key]) do
          nil ->
            {:error,
             err(
               :unprocessable_entity,
               "#{id_key} must be an integer id (got #{inspect(data[id_key])}).",
               422,
               id_key
             )}

          n ->
            {:ok, n}
        end

      Map.has_key?(data, base) ->
        case normalize_int(data[base]) do
          nil ->
            {:error,
             err(
               :unprocessable_entity,
               "#{base} must be an integer id (got #{inspect(data[base])}).",
               422,
               base
             )}

          n ->
            {:ok, n}
        end

      required? ->
        {:error,
         err(
           :unprocessable_entity,
           "Missing required reference #{id_key} (or #{lid_key}).",
           422,
           id_key
         )}

      true ->
        {:ok, nil}
    end
  end

  defp resolve_lid(changes, lid, expected_type) do
    case Map.get(lid_map(changes), lid) do
      nil ->
        {:error, err(:bad_reference, "Unknown or forward local id #{inspect(lid)}.", 422)}

      %{id: id, type: ^expected_type} ->
        {:ok, id}

      %{type: other} ->
        {:error,
         err(
           :bad_reference,
           "Local id #{inspect(lid)} refers to a #{other}, but a #{expected_type} was expected.",
           422
         )}
    end
  end

  # A task create needs both an Initiative and a parent. The parent may be a lid
  # (a task created earlier in this batch); the Initiative may be given directly
  # or derived from the resolved parent task.
  defp resolve_task_parentage(data, changes) do
    with {:ok, parent_id} <- resolve_ref_field(data, "parent", changes, "task", required: false),
         {:ok, initiative_id} <- resolve_initiative_for_create(data, changes, parent_id) do
      cond do
        is_nil(initiative_id) ->
          {:error,
           err(
             :unprocessable_entity,
             "A task create needs initiative_id (or initiative_lid), or a resolvable parent.",
             422,
             "initiative_id"
           )}

        # An `add task` that names an Initiative but no parent defaults to a
        # TOP-LEVEL task: its parent is that Initiative's root task. This lets a
        # single batch create an Initiative (lid) and its first top-level task
        # referencing it via `initiative_lid` — no two-round-trip bootstrap, and
        # without the caller needing the root_task_id (which isn't referenceable
        # as a parent_lid for a just-created Initiative). The Initiative is
        # resolved through the same path (a same-batch lid already resolved to
        # its real id), and the :edit authz + parent_in_initiative guard below
        # still apply to the root parent unchanged.
        is_nil(parent_id) ->
          with {:ok, root_id} <- initiative_root_task_id(initiative_id) do
            {:ok, initiative_id, root_id}
          end

        true ->
          {:ok, initiative_id, parent_id}
      end
    end
  end

  # The Initiative's root task id, the implicit parent of a top-level task.
  # Resolved within the transaction, so a same-batch initiative create is
  # visible. Authz still runs on the create itself (below), so reading the id
  # here leaks nothing the caller can't already address.
  defp initiative_root_task_id(initiative_id) do
    case Initiatives.get_initiative(initiative_id) do
      %Initiative{root_task_id: root_id} when not is_nil(root_id) ->
        {:ok, root_id}

      %Initiative{} ->
        {:error,
         err(
           :unprocessable_entity,
           "Initiative #{initiative_id} has no root task.",
           422,
           "initiative_id"
         )}

      nil ->
        {:error, err(:not_found, "No such Initiative with id #{initiative_id}.", 422)}
    end
  end

  defp resolve_initiative_for_create(data, changes, parent_id) do
    cond do
      is_binary(data["initiative_lid"]) or Map.has_key?(data, "initiative_id") or
          Map.has_key?(data, "initiative") ->
        resolve_ref_field(data, "initiative", changes, "initiative", required: false)

      not is_nil(parent_id) ->
        case load_task(parent_id) do
          {:ok, %Task{initiative_id: id}} -> {:ok, id}
          error -> error
        end

      true ->
        {:ok, nil}
    end
  end

  # The parent task MUST belong to the same Initiative the create targets.
  # Without this, an explicit `initiative_id` paired with a foreign `parent_id`
  # would (a) authorize only against the caller's own Initiative yet (b) write a
  # child row straddling two Initiatives and walk the FOREIGN ancestor chain in
  # reconcile_after_create (which is unscoped by initiative) — a cross-initiative
  # mutation of an Initiative the caller has no role on. Mirrors validate_move's
  # cross-initiative guard. (On the derived path initiative_id IS the parent's,
  # so this trivially holds.)
  defp parent_in_initiative(%Task{initiative_id: id}, initiative_id) when id == initiative_id,
    do: :ok

  defp parent_in_initiative(parent, initiative_id),
    do:
      {:error,
       err(
         :unprocessable_entity,
         "parent_id #{parent.id} belongs to Initiative #{parent.initiative_id}, not Initiative #{initiative_id}.",
         422,
         "parent_id"
       )}

  # --- assignee / co-assignee membership parity ------------------------------
  #
  # The token only identifies the caller; the Tasks context fns set assignee_id
  # / co-assignee links and fire assignment notifications WITHOUT checking the
  # target is a member of the task's Initiative — the LiveView pre-gates that
  # (member_id?/staff_pool_allows?). So the API must enforce the same parity
  # here, before delegating, or an owner/editor could assign a task to a
  # stranger and leak the task title + initiative_id + actor name into that
  # non-member's notification feed. A non-member target is a clean per-op error
  # that rolls the batch back: nothing persisted, no notification. Reuses the
  # existing membership rows (Initiatives.get_role/membership_map), not a
  # reimplementation.

  # A nil/absent assignee = no change / unassign; only a real id is checked. The
  # acting user, having passed the :edit authz, is itself a member.
  defp validate_assignee_membership(initiative_id, data) do
    case normalize_int(Map.get(data, "assignee_id")) do
      nil ->
        :ok

      id ->
        if Initiatives.get_role(initiative_id, id),
          do: :ok,
          else: not_a_member_error(id, initiative_id, "assignee_id")
    end
  end

  # One membership lookup for the whole desired co-assignee list; a stranger
  # anywhere in it rejects the op.
  defp validate_co_assignee_membership(initiative_id, ids) do
    members = Initiatives.membership_map(initiative_id)

    case Enum.find(ids, &(not Map.has_key?(members, &1))) do
      nil -> :ok
      stranger -> not_a_member_error(stranger, initiative_id, "co_assignee_ids")
    end
  end

  defp not_a_member_error(user_id, initiative_id, pointer) do
    {:error,
     err(
       :unprocessable_entity,
       "User #{user_id} is not a member of Initiative #{initiative_id}.",
       422,
       pointer
     )}
  end

  # --- target resolution (update/remove) -------------------------------------

  defp fetch_task_target(op, changes) do
    with {:ok, id} <- fetch_target_ref(op, changes, "task") do
      load_task(id)
    end
  end

  defp fetch_comment_target(op, changes) do
    with {:ok, id} <- fetch_target_ref(op, changes, "comment") do
      case Tasks.get_comment(id) do
        %Comment{} = comment -> {:ok, comment}
        nil -> {:error, err(:not_found, "No such comment with id #{id}.", 422)}
      end
    end
  end

  # The op's target: a literal `id`, or a `lid` referencing a prior create.
  defp fetch_target_ref(op, changes, expected_type) do
    cond do
      is_binary(op["lid"]) ->
        resolve_lid(changes, op["lid"], expected_type)

      Map.has_key?(op, "id") ->
        fetch_target_id(op)

      true ->
        {:error,
         err(:unprocessable_entity, "Operation is missing its target \"id\" (or \"lid\").", 422)}
    end
  end

  defp fetch_target_id(op) do
    case normalize_int(op["id"]) do
      nil ->
        {:error,
         err(
           :unprocessable_entity,
           "Operation \"id\" must be an integer (got #{inspect(op["id"])}).",
           422
         )}

      n ->
        {:ok, n}
    end
  end

  # --- loaders & authz -------------------------------------------------------

  defp load_task(nil), do: {:error, err(:not_found, "No such task.", 422)}

  defp load_task(id) do
    case Tasks.get_task(id) do
      %Task{deleted_at: nil} = task -> {:ok, task}
      _ -> {:error, err(:not_found, "No such task with id #{id}.", 422)}
    end
  end

  # Loads a task by id even when it's soft-deleted (Trashed). Only `remove link`
  # uses this — detaching a link whose endpoint was since trashed is valid cleanup.
  defp load_task_any(nil), do: {:error, err(:not_found, "No such task.", 422)}

  defp load_task_any(id) do
    case Tasks.get_task(id) do
      %Task{} = task -> {:ok, task}
      nil -> {:error, err(:not_found, "No such task with id #{id}.", 422)}
    end
  end

  defp load_notification(id) do
    case Notifications.get(id) do
      %Notification{} = notification -> {:ok, notification}
      nil -> {:error, err(:not_found, "No such notification with id #{id}.", 422)}
    end
  end

  defp own_notification(%User{id: uid}, %Notification{user_id: uid}), do: :ok

  defp own_notification(_user, notification),
    do: {:error, err(:forbidden, "Notification #{notification.id} belongs to another user.", 403)}

  # Resolve the Initiative and run the capability check through the SAME role
  # predicates the LiveView uses. fetch_initiative returns :not_found (unknown
  # id, or agent access off — m03.04 item 2.12.2) or :forbidden (role denies);
  # map both onto per-op errors. `not_found_override` masks the not-found for
  # task/comment-targeted ops: a target inside a flagged-off Initiative must
  # fail EXACTLY like a nonexistent target (same code + message as load_task /
  # fetch_comment_target), never confirming it exists or naming its Initiative.
  defp authorize(user, initiative_id, capability, not_found_override \\ nil)

  defp authorize(%User{} = user, initiative_id, capability, not_found_override) do
    case Authz.fetch_initiative(user, initiative_id, capability) do
      {:ok, %Initiative{} = initiative} ->
        {:ok, initiative}

      {:error, :not_found} ->
        {:error,
         not_found_override ||
           err(:not_found, "No such Initiative with id #{initiative_id}.", 422)}

      {:error, :forbidden} ->
        {:error,
         err(
           :forbidden,
           "You don't have #{capability} permission for Initiative #{initiative_id}.",
           403
         )}
    end
  end

  defp task_not_found(id), do: err(:not_found, "No such task with id #{id}.", 422)
  defp comment_not_found(id), do: err(:not_found, "No such comment with id #{id}.", 422)

  defp authorize_comment(%User{} = user, %Comment{} = comment, capability) do
    query = from(t in Task, where: t.id == ^comment.task_id, select: t.initiative_id)

    case Repo.one(query) do
      nil ->
        {:error,
         err(:not_found, "The comment's task (id #{comment.task_id}) no longer exists.", 422)}

      initiative_id ->
        authorize(user, initiative_id, capability, comment_not_found(comment.id))
    end
  end

  # --- value helpers ---------------------------------------------------------

  defp data(op), do: Map.get(op, "data", %{}) || %{}

  defp take(data, keys), do: Map.take(data, keys)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp fetch_int(data, key) do
    case normalize_int(data[key]) do
      nil ->
        {:error,
         err(
           :unprocessable_entity,
           "#{key} must be an integer id (got #{inspect(data[key])}).",
           422,
           key
         )}

      n ->
        {:ok, n}
    end
  end

  defp fetch_role(data) do
    case data["role"] do
      role when role in ~w(editor viewer) ->
        {:ok, role}

      "owner" ->
        # Minting an owner-role member grants admin capability via a non-transfer
        # path and can leave multiple owners — bypassing the guarded
        # transfer-ownership flow. Ownership stays LiveView-only, consistent with
        # the owner_id-transfer rejection on `update initiative`.
        {:error,
         err(
           :irreversible_op,
           "Assigning the owner role is not available via the API — ownership changes go through the LiveView-only transfer flow.",
           422,
           "role"
         )}

      _ ->
        {:error,
         err(
           :unprocessable_entity,
           "role must be one of: editor, viewer (got #{inspect(data["role"])}).",
           422,
           "role"
         )}
    end
  end

  defp normalize_int(nil), do: nil
  defp normalize_int(n) when is_integer(n), do: n

  defp normalize_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp normalize_int(_), do: nil

  # --- result builders -------------------------------------------------------

  # The per-step value the Multi accumulates: lid (registered for forward refs),
  # the real id + type (also for refs), and the serialized resource for the
  # success response.
  defp ok(lid, id, type, data) do
    {:ok, %{lid: lid, id: id, type: type, data: data}}
  end

  defp task_result(%Task{} = task) do
    %{
      id: task.id,
      type: "task",
      title: task.title,
      parent_id: task.parent_id,
      status: task.status,
      done: task.status == "done",
      progress: task.computed_progress,
      manual_progress: task.manual_progress,
      priority: task.priority,
      assignee_id: task.assignee_id
    }
  end

  defp initiative_result(%Initiative{} = initiative) do
    %{
      id: initiative.id,
      type: "initiative",
      name: initiative.name,
      root_task_id: initiative.root_task_id,
      progress_calc: initiative.progress_calc,
      index_style: initiative.index_style,
      ai_knobs: initiative.ai_knobs
    }
  end

  defp comment_result(%Comment{} = comment) do
    deleted? = Tasks.comment_deleted?(comment)

    %{
      id: comment.id,
      type: "comment",
      task_id: comment.task_id,
      body: if(deleted?, do: nil, else: comment.body),
      author_id: comment.user_id,
      deleted: deleted?
    }
  end

  defp member_result(initiative_id, user_id, role) do
    %{type: "member", initiative_id: initiative_id, user_id: user_id, role: role}
  end

  defp link_result(link, %Task{} = source, %Task{} = target) do
    %{
      id: link.id,
      type: "link",
      source_task_id: source.id,
      target_task_id: target.id
    }
  end

  # --- error helpers ---------------------------------------------------------

  defp err(code, message, http, pointer \\ nil) do
    %{code: to_string(code), message: message, pointer: pointer, http: http}
  end

  # Translate a domain context error into a per-op error.
  defp context_error(%Ecto.Changeset{} = changeset) do
    {message, pointer} = first_changeset_error(changeset)
    err(:unprocessable_entity, message, 422, pointer)
  end

  defp context_error(:forbidden),
    do: err(:forbidden, "You don't have permission for this operation.", 403)

  defp context_error(:unauthorized),
    do: err(:forbidden, "Only the author may edit or delete this comment.", 403)

  defp context_error(:not_found),
    do: err(:not_found, "The referenced resource was not found.", 422)

  defp context_error(:cross_initiative),
    do: err(:unprocessable_entity, "A task can't move across Initiatives.", 422, "parent_id")

  defp context_error(:cycle),
    do: err(:unprocessable_entity, "That move would create a cycle.", 422, "parent_id")

  defp context_error(:is_primary),
    do:
      err(
        :unprocessable_entity,
        "That user is already the primary assignee.",
        422,
        "co_assignee_ids"
      )

  defp context_error(:already_co),
    do: err(:unprocessable_entity, "That user is already a co-assignee.", 422, "co_assignee_ids")

  defp context_error(:already_member),
    do: err(:unprocessable_entity, "That user is already a member.", 422, "user_id")

  defp context_error(:not_a_member),
    do: err(:unprocessable_entity, "That user is not a member.", 422, "user_id")

  defp context_error(reason) when is_atom(reason),
    do: err(:unprocessable_entity, humanize(reason), 422)

  defp first_changeset_error(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      interpolated =
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)

      {interpolated, opts}
    end)
    |> Enum.find_value({"is invalid", nil}, fn {field, [{first, opts} | _]} ->
      {error_message(field, first, opts), to_string(field)}
    end)
  end

  # The description-length 422 carries the overflow doctrine (m03.04 fix 22),
  # read at the exact moment an agent would otherwise invent continuation
  # tasks. Matched on field + validation, not message text.
  defp error_message(:description, message, opts) do
    if opts[:validation] == :length and opts[:kind] == :max do
      "description #{message} — trim the prose and cite the source doc path in the " <>
        "provenance comment; do not split the remainder into continuation tasks."
    else
      "description #{message}"
    end
  end

  defp error_message(field, message, _opts), do: "#{field} #{message}"

  defp humanize(reason), do: reason |> to_string() |> String.replace("_", " ")
end
