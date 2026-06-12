defmodule DoIt.AccountsTest do
  use DoIt.DataCase, async: true

  alias DoIt.Accounts
  alias DoIt.Accounts.User

  defp register!(attrs \\ %{}) do
    defaults = %{
      "email" => "user-#{System.unique_integer([:positive])}@example.com",
      "username" => "user-#{System.unique_integer([:positive])}",
      "name" => "Some User",
      "password" => "password123"
    }

    {:ok, user} = Accounts.register_user(Map.merge(defaults, attrs))
    user
  end

  describe "registration (§1.4)" do
    test "requires a username" do
      {:error, changeset} =
        Accounts.register_user(%{
          "email" => "nouser@example.com",
          "name" => "No User",
          "password" => "password123"
        })

      assert "can't be blank" in errors_on(changeset).username
    end

    test "normalizes the username on the way in" do
      user = register!(%{"username" => "MiXeD_Case"})
      assert user.username == "mixed_case"
    end
  end

  describe "login by username or email (§1.5)" do
    test "authenticates by email or username, case-insensitively" do
      user =
        register!(%{
          "username" => "loginuser",
          "email" => "login-target@example.com",
          "password" => "password123"
        })

      assert {:ok, %User{id: id}} = Accounts.authenticate("login-target@example.com", "password123")
      assert id == user.id

      assert {:ok, %User{id: ^id}} = Accounts.authenticate("LoginUser", "password123")
      assert {:ok, %User{id: ^id}} = Accounts.authenticate("  loginuser  ", "password123")

      assert {:error, :invalid_credentials} = Accounts.authenticate("loginuser", "wrong-pass")
      assert {:error, :invalid_credentials} = Accounts.authenticate("nobody", "password123")
    end
  end

  describe "username rules (m02.04 §1.2)" do
    test "accepts the allowed charset, trims and downcases" do
      user = register!()

      changeset = User.username_changeset(user, %{"username" => "  Nate_B-99  "})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :username) == "nate_b-99"
    end

    test "rejects bad charsets, bad leading chars, and bad lengths" do
      user = register!()

      for bad <- ["with space", "dots.are.out", "ab", "-leading-dash", "_leading_underscore", String.duplicate("a", 31)] do
        changeset = User.username_changeset(user, %{"username" => bad})
        refute changeset.valid?, "expected #{inspect(bad)} to be rejected"
      end
    end

    test "is required" do
      changeset = User.username_changeset(register!(), %{"username" => ""})
      refute changeset.valid?
    end

    test "enforces uniqueness case-insensitively" do
      taken = register!()
      {:ok, taken} = taken |> User.username_changeset(%{"username" => "shared"}) |> Repo.update()

      other = register!()
      changeset = User.username_changeset(other, %{"username" => "SHARED"})

      refute changeset.valid?
      assert {"has already been taken", _} = changeset.errors[:username]
      assert taken.username == "shared"
    end
  end
end
