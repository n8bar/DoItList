defmodule DoItWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  alias DoItWeb.CoreComponents

  describe "avatar derivation (m02.04 §1.11)" do
    test "initials come from the display name's first and last words" do
      assert CoreComponents.initials(%{name: "Nate Barlow", username: "nate"}) == "NB"
      assert CoreComponents.initials(%{name: "Cher", username: "cher"}) == "C"
      assert CoreComponents.initials(%{name: "Ana de la Cruz", username: "ana"}) == "AC"
    end

    test "falls back to the username when the name is blank" do
      assert CoreComponents.initials(%{name: "", username: "zed99"}) == "ZE"
      assert CoreComponents.initials(%{name: nil, username: "zed99"}) == "ZE"
    end

    test "color is deterministic per user id" do
      a = CoreComponents.avatar_bg(%{id: 1})
      assert a == CoreComponents.avatar_bg(%{id: 1})
      assert String.starts_with?(a, "#")
    end
  end
end
