defmodule DoIt.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :theme, :string

    timestamps(type: :utc_datetime)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :password])
    |> validate_required([:email, :name, :password])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, message: "must be a valid email")
    |> update_change(:email, &String.downcase(&1))
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, DoIt.Repo)
    |> unique_constraint(:email)
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
  end

  def login_changeset(attrs) do
    {%{}, %{email: :string, password: :string}}
    |> cast(attrs, [:email, :password])
    |> validate_required([:email, :password])
    |> update_change(:email, &String.downcase(&1))
  end

  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end

  def valid_password?(%__MODULE__{hashed_password: hashed}, password)
      when is_binary(hashed) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end
end
