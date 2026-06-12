defmodule DoIt.AccountsTest do
  use DoIt.DataCase, async: true

  alias DoIt.Accounts
  alias DoIt.Accounts.User

  defp register!(attrs \\ %{}) do
    defaults = %{
      "email" => "user-#{System.unique_integer([:positive])}@example.com",
      "name" => "Some User",
      "password" => "password123"
    }

    {:ok, user} = Accounts.register_user(Map.merge(defaults, attrs))
    user
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
