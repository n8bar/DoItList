defmodule DoItWeb.CollaboratorAdd do
  @moduledoc """
  The rail's collaborator add — click/drag onto an initiative entry — shared
  by every LiveView that renders the rail: the workspace and `/assigned`
  (m03.04 items 2.16/2.21).

  Owns the core the views must not let drift: add as viewer, the
  proof-carrying trust ack (`trust_confirmed` is injected ONLY by the trust
  confirm's Proceed, and the ack records only when the predicate still holds
  AND the add commits — never from a bare push that merely matches the
  trigger), and the outcome flash. Callers do their own post-add refreshes
  (their rail assigns differ) and reply `%{ok: ...}` so the optimistic rail
  chip reconciles (MUST NOT LIE).
  """

  import Phoenix.LiveView, only: [put_flash: 3]

  alias DoIt.Accounts.User
  alias DoIt.Initiatives

  # Client-supplied ids ride Postgres bigint columns.
  @pg_bigint_min -9_223_372_036_854_775_808
  @pg_bigint_max 9_223_372_036_854_775_807

  @doc """
  Parse a client-supplied id param: nil for anything that isn't an in-range
  integer, so the caller no-ops with ok:false (pulling the optimistic chip)
  rather than crashing.
  """
  @spec parse_id(term()) :: integer() | nil
  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= @pg_bigint_min and int <= @pg_bigint_max -> int
      _ -> nil
    end
  end

  def parse_id(_value), do: nil

  @doc """
  Add `uid` to initiative `iid` as a viewer, recording the trust ack when
  Proceed carried the marker and the predicate still requires it. Returns
  `{ok?, ack?, socket}` with the outcome flash set — refreshes are the
  caller's job.
  """
  @spec add_as_viewer(Phoenix.LiveView.Socket.t(), User.t(), integer(), integer(), boolean()) ::
          {boolean(), boolean(), Phoenix.LiveView.Socket.t()}
  def add_as_viewer(socket, %User{} = user, iid, uid, trust_confirmed?) do
    target = if trust_confirmed?, do: Initiatives.get_initiative(iid)

    ack? =
      target != nil and
        Initiatives.agent_trust_confirm_required?(user, target, {:add_member, "viewer"})

    case Initiatives.add_collaborator_as_viewer(user, iid, uid) do
      {:ok, added} ->
        if ack?, do: Initiatives.record_agent_trust_ack(user, target)
        {true, ack?, put_flash(socket, :info, "Added #{added.name} as a viewer.")}

      # Already a member → the real row is already present; treat the optimistic
      # chip as not-needed (ok:false pulls the dimmed stand-in; the flash is
      # informational, no lie left behind).
      {:error, :already_member} ->
        {false, false, put_flash(socket, :info, "They're already a member there.")}

      {:error, :forbidden} ->
        {false, false, put_flash(socket, :error, "Only that Initiative's owner can add members.")}

      {:error, :failed} ->
        {false, false, put_flash(socket, :error, "Couldn't add them.")}
    end
  end
end
