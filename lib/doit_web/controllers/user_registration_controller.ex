defmodule DoItWeb.UserRegistrationController do
  use DoItWeb, :controller

  import Phoenix.Component, only: [to_form: 1]

  alias DoIt.Accounts
  alias DoIt.Accounts.User
  alias DoItWeb.UserAuth

  def new(conn, _params) do
    changeset = Accounts.change_user_registration(%User{})
    render(conn, :new, changeset: changeset, form: to_form(changeset))
  end

  def create(conn, %{"user" => params}) do
    case Accounts.register_user(params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "Welcome to Do It List, #{user.name}.")
        |> UserAuth.log_in_user(user)

      {:error, changeset} ->
        conn
        |> put_flash(:error, "Could not register. Check the errors below.")
        |> render(:new, changeset: changeset, form: to_form(changeset))
    end
  end
end
