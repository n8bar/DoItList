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

  # m03.04 6.1: a deep link followed while logged out must survive the login
  # round trip. The requested path is parked here (session, not a query param on
  # the form) so the login POST needs no extra field.
  @return_to_key :user_return_to

  # --- Plug ------------------------------------------------------------------

  @doc """
  Logs the user in by storing their id in the session, and renews the session
  to defend against session fixation.

  Lands on the path parked by `store_return_to/2` when there is one, otherwise
  the Initiative list. The parked path is read before `renew_session/1` wipes
  it, so it is consumed exactly once either way.
  """
  def log_in_user(conn, user) do
    return_to = local_return_path(get_session(conn, @return_to_key))

    conn
    |> renew_session()
    |> put_session(@session_key, user.id)
    |> redirect(to: return_to || ~p"/initiatives")
  end

  @doc """
  Parks `path` as the post-login destination, when it is a safe local path.

  Anything else (a fully qualified URL, a scheme-relative `//host` reference, a
  `javascript:` payload) is dropped rather than stored, so the session can never
  hold an open-redirect target.
  """
  def store_return_to(conn, path) do
    case local_return_path(path) do
      nil -> conn
      path -> put_session(conn, @return_to_key, path)
    end
  end

  @doc """
  Returns `path` when it is a local, same-app redirect target, else `nil`.

  Local means a single leading `/` (never `//` or `/\\`, which browsers read as
  scheme-relative), no scheme, and no whitespace or control characters that
  could smuggle one past the checks above.
  """
  def local_return_path(path) when is_binary(path) do
    cond do
      not String.starts_with?(path, "/") -> nil
      String.starts_with?(path, ["//", "/\\"]) -> nil
      String.contains?(path, "://") -> nil
      String.match?(path, ~r/[\x00-\x20\x7f]/) -> nil
      true -> path
    end
  end

  def local_return_path(_path), do: nil

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
      |> maybe_store_request_path()
      |> put_flash(:error, "You must be logged in.")
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  # Only a GET is worth returning to: it is the one the browser can replay after
  # login. A halted POST/DELETE parks nothing.
  defp maybe_store_request_path(%Plug.Conn{method: "GET"} = conn),
    do: store_return_to(conn, current_path(conn))

  defp maybe_store_request_path(conn), do: conn

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

    cond do
      user && user.password_change_required && socket.view != DoItWeb.AccountLive ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(
           :error,
           "You must change your password before continuing."
         )
         |> Phoenix.LiveView.redirect(to: ~p"/account")}

      user ->
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

      true ->
        {:halt,
         socket
         |> Phoenix.LiveView.put_flash(:error, "You must be logged in.")
         |> Phoenix.LiveView.redirect(to: log_in_path(socket))}
    end
  end

  # A halted mount has no conn to park the path in, so it hands the path to the
  # login page instead; `UserSessionController.new/2` parks it there. Reached
  # only when the socket connects without a user (the plug already covers the
  # dead render), so it must recover the path from the socket's connect info —
  # `:uri` is declared on the LiveView socket in the endpoint for this.
  defp log_in_path(socket) do
    case connect_uri_path(socket) do
      nil -> ~p"/users/log_in"
      path -> ~p"/users/log_in?#{[return_to: path]}"
    end
  end

  defp connect_uri_path(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :uri) do
      %URI{path: path} = uri when is_binary(path) ->
        local_return_path(append_query(path, uri.query))

      _ ->
        nil
    end
  end

  defp append_query(path, query) when query in [nil, ""], do: path
  defp append_query(path, query), do: path <> "?" <> query

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
