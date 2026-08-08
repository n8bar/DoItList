defmodule DoIt.ImportConfirms do
  @moduledoc """
  Server-recorded import confirms (m03.04 item 30) — the enforcement-grade
  channel for the MCP import gate's readback confirm.

  A gated `apply_operations` PARKS a pending confirm here over the HTTP API
  (readback verbatim, a `payload_hash` binding it to the exact batch, homed
  on the target Initiative or on the account for bootstrap batches). The
  operator decides in the app — Approve / Correct (with text) / Hold — and
  the adapter READS the decision back by hash on the re-call. The security
  invariant: decisions are never writable through the HTTP API. The agent
  holds the operator's bearer token, so an API decision-write would let it
  approve its own confirm; `decide/4` is called only from the app's UI.

  Park idempotency: an existing PENDING row for the same home + hash is
  returned as-is (no duplicate cards); a decided row does NOT block a new
  park — a re-park after hold/correct opens a fresh pending row, so a
  changed batch re-parks and a same-batch retry after a hold is re-asked.

  Each park and decision broadcasts on the owner's per-user topic
  (`user_topic/1`) via `DoIt.Broadcast`, so an open page shows/clears the
  card live — the card appearing IS the notification.
  """

  import Ecto.Query, warn: false

  alias DoIt.Accounts.User
  alias DoIt.ImportConfirms.ImportConfirm
  alias DoIt.Repo

  @decisions ~w(approved corrected held)

  @doc "The PubSub topic carrying a user's import-confirm events."
  def user_topic(user_id), do: "import_confirms:#{user_id}"

  @doc "Subscribe to a user's import-confirm events."
  def subscribe(user_id), do: Phoenix.PubSub.subscribe(DoIt.PubSub, user_topic(user_id))

  @doc """
  Park a confirm for `user`, homed on `initiative_id` (nil = the account).
  `attrs` carries `payload_hash` and `readback`. Idempotent per the moduledoc:
  an existing pending row for the same home + hash is returned as-is;
  otherwise a fresh pending row is inserted and `{:import_confirm_parked,
  confirm}` broadcasts on the owner's topic.
  """
  def park(%User{id: user_id}, initiative_id, attrs) do
    case get_pending(user_id, initiative_id, attrs["payload_hash"] || attrs[:payload_hash]) do
      %ImportConfirm{} = confirm ->
        {:ok, confirm}

      nil ->
        %ImportConfirm{user_id: user_id, initiative_id: initiative_id}
        |> ImportConfirm.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, confirm} ->
            DoIt.Broadcast.broadcast(user_topic(user_id), {:import_confirm_parked, confirm})
            {:ok, confirm}

          error ->
            error
        end
    end
  end

  @doc """
  Record the operator's decision on a pending confirm they own — `status` one
  of `approved` / `corrected` / `held`; `corrections` text rides `corrected`
  (required there, dropped elsewhere). Records ONCE: the update is guarded on
  `status == "pending"`, so a second decision returns `{:error, :not_pending}`
  instead of overwriting. Broadcasts `{:import_confirm_decided, confirm}`.
  """
  def decide(%User{id: user_id}, confirm_id, status, corrections \\ nil)
      when status in @decisions do
    corrections = if status == "corrected", do: presence(corrections), else: nil

    if status == "corrected" and is_nil(corrections) do
      {:error, :corrections_required}
    else
      query =
        from c in ImportConfirm,
          where: c.id == ^confirm_id and c.user_id == ^user_id and c.status == "pending",
          select: c

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      case Repo.update_all(query,
             set: [status: status, corrections: corrections, updated_at: now]
           ) do
        {1, [confirm]} ->
          DoIt.Broadcast.broadcast(user_topic(user_id), {:import_confirm_decided, confirm})
          {:ok, confirm}

        {0, _} ->
          {:error, :not_pending}
      end
    end
  end

  @doc """
  The newest row for `user` + `payload_hash` (any status), or nil — the
  adapter's consult: after a re-park the fresh pending row is the newest, so
  the latest row always reflects where this exact batch stands.
  """
  def latest_by_hash(%User{id: user_id}, payload_hash) when is_binary(payload_hash) do
    Repo.one(
      from c in ImportConfirm,
        where: c.user_id == ^user_id and c.payload_hash == ^payload_hash,
        order_by: [desc: c.id],
        limit: 1
    )
  end

  @doc "Pending confirms `user` owns homed on `initiative_id`, oldest first."
  def list_pending_for_initiative(%User{id: user_id}, initiative_id) do
    Repo.all(
      from c in ImportConfirm,
        where:
          c.user_id == ^user_id and c.initiative_id == ^initiative_id and c.status == "pending",
        order_by: [asc: c.id]
    )
  end

  @doc "Pending confirms `user` owns homed on the account (nil Initiative), oldest first."
  def list_pending_for_account(%User{id: user_id}) do
    Repo.all(
      from c in ImportConfirm,
        where: c.user_id == ^user_id and is_nil(c.initiative_id) and c.status == "pending",
        order_by: [asc: c.id]
    )
  end

  defp get_pending(_user_id, _initiative_id, hash) when not is_binary(hash), do: nil

  defp get_pending(user_id, initiative_id, hash) do
    base =
      from c in ImportConfirm,
        where: c.user_id == ^user_id and c.payload_hash == ^hash and c.status == "pending",
        order_by: [desc: c.id],
        limit: 1

    query =
      case initiative_id do
        nil -> from c in base, where: is_nil(c.initiative_id)
        id -> from c in base, where: c.initiative_id == ^id
      end

    Repo.one(query)
  end

  defp presence(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp presence(_), do: nil
end
