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
    |> redirect(to: ~p"/projects")
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
      |> redirect(to: ~p"/projects")
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
    {:cont, Phoenix.Component.assign(socket, :current_user, user)}
  end

  def on_mount(:require_authenticated, _params, session, socket) do
    user_id = session["user_id"]
    user = user_id && Accounts.get_user(user_id)

    if user do
      {:cont, Phoenix.Component.assign(socket, :current_user, user)}
    else
      {:halt,
       socket
       |> Phoenix.LiveView.put_flash(:error, "You must be logged in.")
       |> Phoenix.LiveView.redirect(to: ~p"/users/log_in")}
    end
  end
end
