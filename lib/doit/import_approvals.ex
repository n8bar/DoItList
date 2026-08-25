defmodule DoIt.ImportApprovals do
  @moduledoc """
  Server-verified import approvals (m03.04 2.8.8) — the operator's one-click
  override for the MCP adapter's open-only bootstrap refusal. A slice of the
  item-30 import-confirm machinery (retired at 2.8.4), revived with two
  decisions instead of three and a TTL instead of an immortal park.

  The refused import PARKS here over the HTTP API (payload hash, task count,
  the batch's Initiative name), always account-homed — a bootstrap batch's
  Initiative doesn't exist yet. The operator decides in the app — Approve /
  Dismiss — and the adapter READS the decision back by hash on the re-send.
  The security invariant: decisions are never writable through the HTTP API.
  The agent holds the operator's bearer token, so an API decision-write would
  let it approve its own import; `decide/3` is called only from the app's UI.

  Park semantics per (user, hash), newest row wins:

    * `approved` — returned as-is; the same batch re-sends and flows.
    * `dismissed` — LATCHED: returned as-is, no fresh park. The operator
      declined this exact payload; a changed batch is a new hash.
    * `pending`, unexpired — returned as-is (idempotent re-park, no
      duplicate cards or notifications).
    * `pending` past the TTL, or nothing — a fresh pending row: the park
      broadcasts on the owner's per-user topic (the open account page shows
      the card live) and a notification fires to the account owner.

  A decision records ONCE (guarded on `pending`) and broadcasts, clearing
  the card on every open page.
  """

  import Ecto.Query, warn: false

  alias DoIt.Accounts.User
  alias DoIt.ImportApprovals.ImportApproval
  alias DoIt.Notifications
  alias DoIt.Repo

  @decisions ~w(approved dismissed)

  # A park is good for a generous day; an expired one simply re-parks (and
  # re-notifies) on the agent's next attempt.
  @ttl_hours 24

  @doc "How long a pending park stands before it expires, in hours."
  def ttl_hours, do: @ttl_hours

  @doc "The PubSub topic carrying a user's import-approval events."
  def user_topic(user_id), do: "import_approvals:#{user_id}"

  @doc "Subscribe to a user's import-approval events."
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(DoIt.PubSub, user_topic(user_id))

  @doc """
  Park an open-only import for `user`'s decision. `attrs` carries
  `payload_hash`, `task_count`, and `initiative_name`. Returns the standing
  row per the moduledoc — decided rows and unexpired pending rows as-is; a
  fresh pending row (broadcast `{:import_approval_parked, approval}` plus an
  `import_approval_requested` notification) otherwise.
  """
  def park(%User{id: user_id}, attrs) do
    case latest_by_hash_id(user_id, attrs["payload_hash"] || attrs[:payload_hash]) do
      %ImportApproval{status: status} = approval when status in @decisions ->
        {:ok, approval}

      %ImportApproval{status: "pending"} = approval ->
        if expired?(approval), do: insert_park(user_id, attrs), else: {:ok, approval}

      nil ->
        insert_park(user_id, attrs)
    end
  end

  defp insert_park(user_id, attrs) do
    %ImportApproval{user_id: user_id}
    |> ImportApproval.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, approval} ->
        DoIt.Broadcast.broadcast(user_topic(user_id), {:import_approval_parked, approval})

        {:ok, _} =
          Notifications.create(user_id, "import_approval_requested", %{
            initiative_name: approval.initiative_name,
            task_count: approval.task_count
          })

        {:ok, approval}

      error ->
        error
    end
  end

  @doc """
  Record the operator's decision on a pending approval they own — `status`
  `approved` or `dismissed`. Records ONCE: the update is guarded on
  `status == "pending"`, so a second decision returns `{:error, :not_pending}`
  instead of overwriting. Broadcasts `{:import_approval_decided, approval}`.
  """
  def decide(%User{id: user_id}, approval_id, status, reason \\ nil)
      when status in @decisions do
    query =
      from a in ImportApproval,
        where: a.id == ^approval_id and a.user_id == ^user_id and a.status == "pending",
        select: a

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    reason = trimmed(reason)

    case Repo.update_all(query,
           set: [status: status, decision_reason: reason, updated_at: now]
         ) do
      {1, [approval]} ->
        approval = %{approval | decision_reason: reason}
        DoIt.Broadcast.broadcast(user_topic(user_id), {:import_approval_decided, approval})
        {:ok, approval}

      {0, _} ->
        {:error, :not_pending}
    end
  end

  # The operator's rejection words — blank collapses to nil so the agent is
  # told there were none rather than shown an empty quote. Capped so an
  # accident can't push a wall of text into an agent's context (2.11.2).
  defp trimmed(reason) when is_binary(reason) do
    case reason |> String.trim() |> String.slice(0, 500) do
      "" -> nil
      text -> text
    end
  end

  defp trimmed(_), do: nil

  @doc """
  The newest row for `user` + `payload_hash` (any status), or nil — the
  adapter's consult: approved flows, dismissed latches the refusal, anything
  else re-parks.
  """
  def latest_by_hash(%User{id: user_id}, payload_hash) when is_binary(payload_hash) do
    latest_by_hash_id(user_id, payload_hash)
  end

  defp latest_by_hash_id(_user_id, hash) when not is_binary(hash), do: nil

  defp latest_by_hash_id(user_id, hash) do
    Repo.one(
      from a in ImportApproval,
        where: a.user_id == ^user_id and a.payload_hash == ^hash,
        order_by: [desc: a.id],
        limit: 1
    )
  end

  @doc "Pending, unexpired approvals `user` owns, oldest first — the account page's cards."
  def list_pending_for_account(%User{id: user_id}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@ttl_hours, :hour)

    Repo.all(
      from a in ImportApproval,
        where: a.user_id == ^user_id and a.status == "pending" and a.inserted_at > ^cutoff,
        order_by: [asc: a.id]
    )
  end

  @doc "Whether a pending park has outlived the TTL."
  def expired?(%ImportApproval{inserted_at: inserted_at}) do
    DateTime.diff(DateTime.utc_now(), inserted_at, :hour) >= @ttl_hours
  end
end
