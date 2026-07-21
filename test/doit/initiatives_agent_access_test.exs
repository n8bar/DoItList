defmodule DoIt.InitiativesAgentAccessTest do
  @moduledoc """
  m03.04 item 2.12 — per-Initiative agent access, off by default, and the
  one-time agent-trust acknowledgement:

    * creation defaults both ways: UI-created Initiatives land off; the
      `agent_access: true` option (the API/MCP create path) lands on —
      server-side, never cast from attrs.
    * `set_agent_access/2` flips the flag.
    * the trust-confirm trigger predicate on both paths — enabling access over
      existing members, and member add/promote on an agent-accessible
      Initiative — and its permanent suppression once acknowledged.
    * ack persistence: recorded per (admin, Initiative), idempotent.
  """
  use DoIt.DataCase, async: true

  alias DoIt.{Accounts, Initiatives}

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => name,
        "password" => "password123"
      })

    u
  end

  describe "creation defaults" do
    test "a UI-created Initiative lands with agent access OFF" do
      owner = user("Ann")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Plain"})

      assert Initiatives.get_initiative(ini.id).agent_access == false
    end

    test "the agent_access: true option (API create path) lands ON, server-side" do
      owner = user("Ann")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Api"}, agent_access: true)

      assert Initiatives.get_initiative(ini.id).agent_access == true
    end

    test "agent_access in attrs is NOT cast — only the option grants it" do
      owner = user("Ann")

      {:ok, ini} =
        Initiatives.create_initiative(owner, %{"name" => "Sneaky", "agent_access" => true})

      assert Initiatives.get_initiative(ini.id).agent_access == false
    end
  end

  describe "set_agent_access/2" do
    test "flips the flag on and off" do
      owner = user("Ann")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Flip"})

      {:ok, on} = Initiatives.set_agent_access(ini, true)
      assert on.agent_access == true

      {:ok, off} = Initiatives.set_agent_access(on, false)
      assert off.agent_access == false
    end
  end

  describe "agent_trust_confirm_required?/3 — enable path" do
    test "enabling with no other members needs no confirm" do
      owner = user("Ann")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Solo"})

      refute Initiatives.agent_trust_confirm_required?(owner, ini, :enable_agent_access)
    end

    test "enabling over an existing member needs the confirm" do
      owner = user("Ann")
      bob = user("Bob")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Shared"})
      {:ok, _} = Initiatives.add_member(ini.id, bob.id, "viewer")

      assert Initiatives.agent_trust_confirm_required?(owner, ini, :enable_agent_access)
    end
  end

  describe "agent_trust_confirm_required?/3 — member add/promote path" do
    setup do
      owner = user("Ann")
      bob = user("Bob")
      {:ok, off} = Initiatives.create_initiative(owner, %{"name" => "Off"})
      {:ok, on} = Initiatives.create_initiative(owner, %{"name" => "On"}, agent_access: true)
      %{owner: owner, bob: bob, off: off, on: on}
    end

    test "adding a member (any role — every role is viewer+) confirms only when access is on",
         ctx do
      assert Initiatives.agent_trust_confirm_required?(ctx.owner, ctx.on, {:add_member, "viewer"})
      assert Initiatives.agent_trust_confirm_required?(ctx.owner, ctx.on, {:add_member, "editor"})

      refute Initiatives.agent_trust_confirm_required?(
               ctx.owner,
               ctx.off,
               {:add_member, "viewer"}
             )

      refute Initiatives.agent_trust_confirm_required?(
               ctx.owner,
               ctx.off,
               {:add_member, "editor"}
             )
    end

    test "promoting confirms; demoting or re-setting the same role never does", ctx do
      # viewer -> editor is a rank increase.
      assert Initiatives.agent_trust_confirm_required?(
               ctx.owner,
               ctx.on,
               {:promote_member, "viewer", "editor"}
             )

      # editor -> viewer is a demotion; viewer -> viewer is a no-op.
      refute Initiatives.agent_trust_confirm_required?(
               ctx.owner,
               ctx.on,
               {:promote_member, "editor", "viewer"}
             )

      refute Initiatives.agent_trust_confirm_required?(
               ctx.owner,
               ctx.on,
               {:promote_member, "viewer", "viewer"}
             )

      # A promotion on a flagged-off Initiative never confirms.
      refute Initiatives.agent_trust_confirm_required?(
               ctx.owner,
               ctx.off,
               {:promote_member, "viewer", "editor"}
             )
    end
  end

  describe "acknowledgement persistence" do
    test "recording the ack suppresses the confirm on BOTH paths, and is idempotent" do
      owner = user("Ann")
      bob = user("Bob")
      {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Trusted"})
      {:ok, _} = Initiatives.add_member(ini.id, bob.id, "viewer")

      refute Initiatives.agent_trust_acked?(owner.id, ini.id)
      assert Initiatives.agent_trust_confirm_required?(owner, ini, :enable_agent_access)

      :ok = Initiatives.record_agent_trust_ack(owner, ini)
      # Idempotent: a second record is a clean no-op.
      :ok = Initiatives.record_agent_trust_ack(owner, ini)

      assert Initiatives.agent_trust_acked?(owner.id, ini.id)
      refute Initiatives.agent_trust_confirm_required?(owner, ini, :enable_agent_access)

      {:ok, ini} = Initiatives.set_agent_access(ini, true)
      refute Initiatives.agent_trust_confirm_required?(owner, ini, {:add_member, "editor"})

      refute Initiatives.agent_trust_confirm_required?(
               owner,
               ini,
               {:promote_member, "viewer", "editor"}
             )
    end

    test "the ack is per (admin, Initiative) — not global to the admin" do
      owner = user("Ann")
      bob = user("Bob")
      {:ok, a} = Initiatives.create_initiative(owner, %{"name" => "A"}, agent_access: true)
      {:ok, b} = Initiatives.create_initiative(owner, %{"name" => "B"}, agent_access: true)
      {:ok, _} = Initiatives.add_member(a.id, bob.id, "viewer")
      {:ok, _} = Initiatives.add_member(b.id, bob.id, "viewer")

      :ok = Initiatives.record_agent_trust_ack(owner, a)

      refute Initiatives.agent_trust_confirm_required?(owner, a, {:add_member, "viewer"})
      assert Initiatives.agent_trust_confirm_required?(owner, b, {:add_member, "viewer"})
    end
  end
end
