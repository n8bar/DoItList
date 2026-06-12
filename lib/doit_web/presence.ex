defmodule DoItWeb.Presence do
  @moduledoc """
  Phoenix.Presence for ephemeral per-initiative state — today just "who has
  which task selected" (m02.04 §1.12). Each InitiativeShowLive process tracks
  itself under the user id on `initiative_presence:<id>`; the metas carry the
  selected task plus the avatar ingredients, so subscribers can render
  without a user lookup.
  """
  use Phoenix.Presence, otp_app: :doit, pubsub_server: DoIt.PubSub
end
