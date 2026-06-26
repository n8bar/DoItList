defmodule DoItWeb.Presence do
  @moduledoc """
  Phoenix.Presence for ephemeral presence state.

  Two scopes:

  * **Per-initiative** (`initiative_presence:<id>`) — "who has which task
    selected" (m02.04 §1.12). Each InitiativeWorkspaceLive process tracks itself
    under the user id while a detail is open (entered on detail-enter, untracked
    on leave/switch — M02.09 WL5.3); the metas carry the selected task plus the
    avatar ingredients, so subscribers render without a user lookup.

  * **Global** (`presence:online`) — "who is logged into the app anywhere"
    (m02.05 item 8). Every authenticated LiveView tracks the user here via the
    `on_mount` hook, so the Collaborators pane can light up an avatar whenever
    that person is connected, regardless of which Initiative (if any) they're
    viewing.
  """
  use Phoenix.Presence, otp_app: :doit, pubsub_server: DoIt.PubSub

  @global_topic "presence:online"

  @doc "The global presence topic to subscribe to / track on."
  def global_topic, do: @global_topic

  @doc "Track the user as online app-wide (called from the authenticated on_mount)."
  def track_global(pid, user_id) do
    track(pid, @global_topic, to_string(user_id), %{online_at: System.system_time(:second)})
  end

  @doc "MapSet of user ids currently online anywhere in the app."
  def global_online_ids do
    @global_topic
    |> list()
    |> Map.keys()
    |> MapSet.new(&String.to_integer/1)
  end
end
