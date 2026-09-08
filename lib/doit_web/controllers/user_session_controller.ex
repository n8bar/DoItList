defmodule DoItWeb.UserSessionController do
  use DoItWeb, :controller

  import Phoenix.Component, only: [to_form: 2]

  alias DoIt.Accounts
  alias DoItWeb.UserAuth

  def new(conn, params) do
    form = to_form(%{"login" => "", "password" => ""}, as: :user)

    # m03.04 6.1: a LiveView mount halted for lack of a session can't touch the
    # session itself, so it forwards the requested path here; park it for
    # `UserAuth.log_in_user/2`. Non-local values are dropped by the store.
    conn
    |> UserAuth.store_return_to(params["return_to"])
    |> render(:new, form: form)
  end

  def create(conn, %{"user" => params}) do
    %{"login" => login, "password" => password} = params

    case Accounts.authenticate(login, password) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Welcome back, #{user.name}.")
        |> UserAuth.log_in_user(user)

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid username/email or password.")
        |> redirect(to: ~p"/users/log_in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out.")
    |> UserAuth.log_out_user()
  end
end
