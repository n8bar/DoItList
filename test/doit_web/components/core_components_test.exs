defmodule DoItWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  alias DoItWeb.CoreComponents

  describe "avatar derivation (m02.04 §1.11)" do
    test "initials come from the display name's first and last words" do
      assert CoreComponents.initials(%{name: "Nate Barlow", username: "nate"}) == "NB"
      assert CoreComponents.initials(%{name: "Cher", username: "cher"}) == "C"
      assert CoreComponents.initials(%{name: "Ana de la Cruz", username: "ana"}) == "AC"
    end

    test "generational suffixes don't steal the surname initial" do
      assert CoreComponents.initials(%{name: "Alvin Bartholomew Cubbins III", username: "al"}) == "AC"
      assert CoreComponents.initials(%{name: "Doris Elenor Fitzgerald Jr.", username: "dor"}) == "DF"
      assert CoreComponents.initials(%{name: "Sam Smith Sr", username: "sam"}) == "SS"
      assert CoreComponents.initials(%{name: "Bo Vance, Jr. III", username: "bo"}) == "BV"
      # A suffix-only "name" still yields something rather than vanishing.
      assert CoreComponents.initials(%{name: "Jr", username: "jay"}) == "J"
    end

    test "falls back to the username when the name is blank" do
      assert CoreComponents.initials(%{name: "", username: "zed99"}) == "ZE"
      assert CoreComponents.initials(%{name: nil, username: "zed99"}) == "ZE"
    end

    test "gradient and text color are deterministic per user id" do
      a = CoreComponents.avatar_bg(%{id: 1})
      assert a == CoreComponents.avatar_bg(%{id: 1})
      assert a =~ ~r/^linear-gradient\(\d+deg, #[0-9a-f]{6}, #[0-9a-f]{6}\)$/

      fg = CoreComponents.avatar_fg(%{id: 1})
      assert fg == CoreComponents.avatar_fg(%{id: 1})
      assert fg =~ ~r/^#[0-9a-f]{6}$/
    end

    test "sequential ids don't repeat a look" do
      looks =
        for id <- 1..40,
            do: {CoreComponents.avatar_bg(%{id: id}), CoreComponents.avatar_fg(%{id: id})}

      assert length(Enum.uniq(looks)) == 40
    end
  end
end
