defmodule DoIt.Initiatives.AgentAccessAck do
  @moduledoc """
  The one-time agent-trust acknowledgement (m03.04 item 2.12.4): a row per
  (admin user, Initiative) recording that this admin saw and accepted the
  trust confirm — they're trusting the Initiative's current AND future
  members' content to be read by their AI agents (member content is a
  prompt-injection surface). Once a row exists the confirm never re-shows for
  that pair, across sessions.

  Both ids are set programmatically (never cast); writes go through
  `DoIt.Initiatives.record_agent_trust_ack/2`, idempotent on the unique
  (user_id, initiative_id) index.
  """
  use Ecto.Schema

  alias DoIt.Accounts.User
  alias DoIt.Initiatives.Initiative

  schema "agent_access_acks" do
    belongs_to :user, User
    belongs_to :initiative, Initiative

    timestamps(type: :utc_datetime)
  end
end
