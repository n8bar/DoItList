defmodule DoIt.Accounts do
  @moduledoc """
  Registration, login, and user lookup.
  """

  import Ecto.Query, warn: false
  alias DoIt.Repo
  alias DoIt.Accounts.{User, UserPreferences}

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

  def change_password(%User{} = user, attrs \\ %{}) do
    User.password_changeset(user, attrs)
  end

  @doc """
  Change the password after verifying the current one. A wrong (or blank)
  current password fails with an error on `:current_password`.
  """
  def update_password(%User{} = user, attrs) do
    changeset = User.password_changeset(user, attrs)

    if User.valid_password?(user, attrs["current_password"] || "") do
      Repo.update(changeset)
    else
      {:error,
       changeset
       |> Ecto.Changeset.add_error(:current_password, "is not your current password")
       |> Map.put(:action, :validate)}
    end
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
  The user's preferences row, or an unsaved defaults struct when they've
  never changed anything — callers read either the same way.
  """
  def get_preferences(%User{id: user_id}) do
    Repo.get_by(UserPreferences, user_id: user_id) || %UserPreferences{user_id: user_id}
  end

  def get_preferences_by_user_id(user_id) do
    Repo.get_by(UserPreferences, user_id: user_id) || %UserPreferences{user_id: user_id}
  end

  def change_preferences(%UserPreferences{} = prefs, attrs \\ %{}) do
    UserPreferences.changeset(prefs, attrs)
  end

  def update_preferences(%User{} = user, attrs) do
    user
    |> get_preferences()
    |> UserPreferences.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Delete the user's account (m02.04 §1.10, m02.06 item 10.3). Owned Initiatives
  with other members are handed off to a successor member (highest-ranked, oldest
  joiner); owned Initiatives with no other members are deleted with the account.
  Memberships cascade and task/comment references nilify at the DB.
  """
  def delete_account(%User{} = user) do
    {:ok, _} =
      Repo.transaction(fn ->
        DoIt.Initiatives.transfer_owned_shared_initiatives(user)
        DoIt.Initiatives.delete_sole_owned_initiatives(user)
        Repo.delete!(user)
      end)

    :ok
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
