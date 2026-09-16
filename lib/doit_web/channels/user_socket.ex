defmodule DoItWeb.UserSocket do
  @moduledoc """
  The browser client's socket (m04.01 item 1.5).

  Authenticated by the **web session**, exactly like every other browser
  surface (resilient-client spec §12): `connect_info: [session: ...]` hands
  `connect/3` the same signed cookie `DoItWeb.UserAuth.fetch_current_user/2`
  reads, so a socket can never outrank the page that opened it. A bearer token
  is never consulted here — the only param the client sends is `_csrf_token`,
  which is not a credential: Phoenix refuses to hand the socket the session
  without it, the same check LiveView's socket makes.

  No session, an unreadable session, or a user id that no longer resolves is
  `:error`: the transport is refused rather than joined as nobody.

  `id/1` is per-user so logging out can drop this user's live sockets
  (`DoItWeb.UserAuth.log_out_user/1` broadcasts `"disconnect"` to it). Other
  tabs of the same user that are still signed in simply reconnect and
  re-authenticate on their own cookie.
  """
  use Phoenix.Socket

  alias DoIt.Accounts
  alias DoIt.Accounts.User

  channel "initiative:*", DoItWeb.InitiativeChannel
  channel "user:*", DoItWeb.UserChannel

  @impl true
  def connect(_params, socket, connect_info) do
    with %{} = session <- Map.get(connect_info, :session),
         user_id when is_integer(user_id) <- session["user_id"],
         %User{} = user <- Accounts.get_user(user_id) do
      {:ok, assign(socket, :current_user, user)}
    else
      _ -> :error
    end
  end

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user.id}"
end
