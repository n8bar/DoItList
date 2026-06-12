defmodule DoIt.Accounts do
  @moduledoc """
  Registration, login, and user lookup.
  """

  import Ecto.Query, warn: false
  alias DoIt.Repo
  alias DoIt.Accounts.User

  def get_user(id), do: Repo.get(User, id)

  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: String.downcase(email))
  end

  # Usernames can't contain "@", so a single lookup over both columns is
  # unambiguous. Both columns store the downcased form.
  def get_user_by_email_or_username(login) when is_binary(login) do
    login = login |> String.trim() |> String.downcase()
    Repo.one(from u in User, where: u.email == ^login or u.username == ^login)
  end

  def list_users do
    Repo.all(from u in User, order_by: u.name)
  end

  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  def change_user_registration(%User{} = user, attrs \\ %{}) do
    User.registration_changeset(user, attrs)
  end

  def change_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  def update_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  def change_username(%User{} = user, attrs \\ %{}) do
    User.username_changeset(user, attrs)
  end

  def update_username(%User{} = user, attrs) do
    user
    |> User.username_changeset(attrs)
    |> Repo.update()
  end

  def authenticate(login, password) when is_binary(login) and is_binary(password) do
    user = get_user_by_email_or_username(login)

    if User.valid_password?(user, password) do
      {:ok, user}
    else
      {:error, :invalid_credentials}
    end
  end

  @doc """
  Update a user's theme preference. Stores nil for "system" (so DaisyUI's
  prefersdark behavior takes over) and "light" / "dark" verbatim for explicit
  overrides.
  """
  def update_theme(%User{} = user, theme) when theme in ~w(system light dark) do
    stored = if theme == "system", do: nil, else: theme

    user
    |> Ecto.Changeset.change(theme: stored)
    |> Repo.update()
  end

  def update_theme(_user, _theme), do: {:error, :invalid_theme}
end
