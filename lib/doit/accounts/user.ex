defmodule DoIt.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :username, :string
    field :name, :string
    field :hashed_password, :string, redact: true
    field :password, :string, virtual: true, redact: true
    field :current_password, :string, virtual: true, redact: true
    field :theme, :string

    # The import-approval ceremony's off-switch (m03.04 2.8.9): true = the
    # open-only park-and-approve stop is dormant for this account (facts and
    # guidance still ride). Deliberately in NO cast list — the only write path
    # is Accounts.set_skip_import_approvals/2 from the app's session-authed UI,
    # so no API/MCP surface (which holds the operator's token) can flip it.
    field :skip_import_approvals, :boolean, default: false

    # Set true to force a change-password redirect after login (e.g. an
    # admin-issued temp password). Programmatic only — no changeset ever
    # casts it from user params.
    field :password_change_required, :boolean, default: false

    # Execution provenance (m03.04 2.10.1): how this actor is acting right
    # now. Nil = browser session (the default); the API token resolver stamps
    # `%{kind: "api_token", token_id: id, token_label: label}` so event
    # recording can say which actor performed a write. Never persisted.
    field :provenance, :map, virtual: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for changing the password. The current-password check lives in
  `Accounts.update_password/2` (save-time only), so live validation doesn't
  flag a half-typed current password.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :current_password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 72)
    |> validate_confirmation(:password, message: "does not match new password")
    |> hash_password()
  end

  @doc """
  Changeset for account-page profile edits. `name` stays the free-form
  display label, distinct from the username. Email is a plain edit — no
  verification mail in M02, but it stays required so a future mailer never
  inherits email-less accounts.
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name, :email])
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, message: "must be a valid email")
    |> update_change(:email, &String.downcase(&1))
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, DoIt.Repo)
    |> unique_constraint(:email)
  end

  @doc """
  Changeset for setting or changing the username.

  Rules: 3–30 chars of `a-z 0-9 _ -`, starting with a letter or digit.
  Input is trimmed and downcased, so matching is case-insensitive by
  construction — the column only ever holds the normalized form.
  """
  def username_changeset(user, attrs) do
    user
    |> cast(attrs, [:username])
    |> validate_required([:username])
    |> validate_username()
  end

  defp validate_username(changeset) do
    changeset
    |> update_change(:username, &(&1 |> String.trim() |> String.downcase()))
    |> validate_length(:username, min: 3, max: 30)
    |> validate_format(:username, ~r/^[a-z0-9][a-z0-9_-]*$/,
      message: "use letters, numbers, _ and -, starting with a letter or number"
    )
    |> unsafe_validate_unique(:username, DoIt.Repo)
    |> unique_constraint(:username)
  end

  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :username, :name, :password])
    |> validate_required([:email, :username, :name, :password])
    |> validate_username()
    |> validate_length(:name, min: 1, max: 80)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, message: "must be a valid email")
    |> update_change(:email, &String.downcase(&1))
    |> validate_length(:email, max: 160)
    |> unsafe_validate_unique(:email, DoIt.Repo)
    |> unique_constraint(:email)
    |> validate_length(:password, min: 8, max: 72)
    |> hash_password()
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
