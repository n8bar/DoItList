defmodule DoItWeb.UserAuth do
  @moduledoc """
  Session-based authentication. Stores `:user_id` in the Plug session and
  exposes plug + LiveView helpers.
  """

  use DoItWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias DoIt.Accounts
  alias DoIt.Notifications

  @session_key :user_id

  # --- Plug ------------------------------------------------------------------

  @doc """
  Logs the user in by storing their id in the session, and renews the session
  to defend against session fixation.
  """
  def log_in_user(conn, user) do
    conn
    |> renew_session()
    |> put_session(@session_key, user.id)
    |> redirect(to: ~p"/initiatives")
  end

  def log_out_user(conn) do
    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  def fetch_current_user(conn, _opts) do
    user_id = get_session(conn, @session_key)
    user = user_id && Accounts.get_user(user_id)
    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must be logged in.")
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  def redirect_if_user_is_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> redirect(to: ~p"/initiatives")
      |> halt()
    else
      conn
    end
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  # --- LiveView mount hook ---------------------------------------------------

  def on_mount(:current_user, _params, session, socket) do
    user_id = session["user_id"]
    user = user_id && Accounts.get_user(user_id)

    socket =
      socket
      |> Phoenix.Component.assign(:current_user, user)
      |> attach_theme_hook()

    {:cont, socket}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    user_id = session["user_id"]
    user = user_id && Accounts.get_user(user_id)

    if user do
      # Mark the user online app-wide (m02.05 item 8) so the Collaborators pane
      # lights up whenever they're connected anywhere, not just in one
      # Initiative. Tracked per LiveView process; drops when the last one dies.
      if Phoenix.LiveView.connected?(socket) do
        DoItWeb.Presence.track_global(self(), user.id)
        # Per-user notifications topic (m02.08 worklist 2): a new notification
        # pushes the nav dot/flyout live on every authenticated LiveView.
        Phoenix.PubSub.subscribe(DoIt.PubSub, Notifications.user_topic(user.id))
      end

      socket =
        socket
        |> Phoenix.Component.assign(:current_user, user)
        |> attach_theme_hook()
        |> attach_notifications_hook()

      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "You must be logged in.")
       |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")}
    end
  end

  # --- Notifications (m02.08 worklist 2) -------------------------------------

  # Wire the per-user notifications feed into any authenticated LiveView without
  # editing each one: a `:handle_info` hook reacts to a live `{:notification,_}`
  # push, and a `:handle_event` hook serves the "mark read" gestures the flyout
  # fires. Both refresh `:current_user` to a fresh struct so the layout (which
  # derives the unread dot + recent list from `current_user`) re-renders — the
  # dot/flyout update server-side, no JS hook involved.
  defp attach_notifications_hook(socket) do
    socket
    |> Phoenix.LiveView.attach_hook(:notifications_push, :handle_info, fn
      {:notification, _notification}, socket ->
        {:halt, refresh_current_user(socket)}

      _msg, socket ->
        {:cont, socket}
    end)
    |> Phoenix.LiveView.attach_hook(:notifications_mark_read, :handle_event, fn
      "mark_notifications_read", _params, socket ->
        case socket.assigns[:current_user] do
          nil ->
            {:halt, socket}

          user ->
            _ = Notifications.mark_all_read(user)
            {:halt, refresh_current_user(socket)}
        end

      _event, _params, socket ->
        {:cont, socket}
    end)
  end

  # Force the layout to re-render its notification dot/flyout. The layout derives
  # those from `current_user` (a function component can't read socket assigns, and
  # the shared `<Layouts.app>` callers don't pass extra attrs), so we must make
  # `:current_user` differ — `assign/3` skips a structurally-equal value. We bump
  # a throwaway in-memory field (`updated_at`, never shown in the header) so the
  # struct differs each push and the layout re-queries the live unread count. No
  # DB write; the persisted record is untouched.
  defp refresh_current_user(socket) do
    case socket.assigns[:current_user] do
      nil -> socket
      user -> Phoenix.Component.assign(socket, :current_user, %{user | updated_at: now()})
    end
  end

  defp now, do: DateTime.utc_now()

  # --- Theme persistence -----------------------------------------------------

  # Attach a global handle_event hook so any LiveView mounted via these
  # on_mount callbacks can persist the user's theme choice without each
  # LiveView reimplementing the handler.
  defp attach_theme_hook(socket) do
    Phoenix.LiveView.attach_hook(socket, :persist_theme, :handle_event, fn
      "set_theme", %{"theme" => theme}, socket ->
        case socket.assigns[:current_user] do
          nil ->
            {:halt, socket}

          user ->
            _ = Accounts.update_theme(user, theme)
            {:halt, socket}
        end

      _event, _params, socket ->
        {:cont, socket}
    end)
  end
end
