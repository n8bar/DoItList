defmodule DoItWeb.UserAuth do
  @moduledoc """
  Session-based authentication. Stores `:user_id` in the Plug session and
  exposes plug + LiveView helpers.
  """

  use DoItWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias DoIt.Accounts

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
      if Phoenix.LiveView.connected?(socket), do: DoItWeb.Presence.track_global(self(), user.id)

      socket =
        socket
        |> Phoenix.Component.assign(:current_user, user)
        |> attach_theme_hook()

      {:cont, socket}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "You must be logged in.")
       |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")}
    end
  end

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
