defmodule DoItWeb.AgentAccessSettingsTest do
  @moduledoc """
  m03.04 items 2.12.3 / 2.12.4 — the workspace side of per-Initiative agent
  access:

    * the owner-only AI-access checkbox and the knobs control whose
      enabled/disabled state derives from the flag, in the control itself;
    * `#agent-trust-state`, the render-known state the client reads at click
      time to decide whether the agent-trust confirm opens (the dialog itself
      opens client-side; these tests pin the predicate inputs it reads);
    * server-side ack recording on both trigger paths (enable-over-members,
      member add / promote), after which `data-acked` flips true for good — the
      second occurrence for the same (admin, Initiative) shows no confirm;
    * the rail collaborator-add path (m03.04 item 2.16): each rail entry
      carries `data-trust-confirm`, the render-known state the client reads at
      click/drop, and the committing `add_collaborator_to` records the same
      proof-carrying ack.
  """
  use DoItWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias DoIt.{Accounts, Initiatives}

  defp user(name) do
    n = System.unique_integer([:positive])

    {:ok, u} =
      Accounts.register_user(%{
        "email" => "#{name}-#{n}@example.com",
        "username" => "#{name}-#{n}",
        "name" => String.capitalize(name),
        "password" => "password123"
      })

    u
  end

  defp log_in(conn, user) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, user.id)
  end

  setup %{conn: conn} do
    owner = user("owner")
    {:ok, ini} = Initiatives.create_initiative(owner, %{"name" => "Alpha Initiative"})
    %{conn: log_in(conn, owner), owner: owner, ini: ini}
  end

  describe "AI-access checkbox + knobs visibility (2.12.3)" do
    test "the owner sees the AI-access checkbox and it toggles on", %{
      conn: conn,
      ini: ini
    } do
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      assert has_element?(view, "#agent-access-toggle")
      refute has_element?(view, "#agent-access-toggle[checked]")
      # AI-KNOBS-PARKED (m03.04): the knobs-control derived-state assertions are
      # dropped while knobs are off the UI; the checkbox coverage stays. Revive
      # them (textarea#ai-knobs[disabled] before/after) with the UI form.

      render_change(view, "set_agent_access", %{"agent_access" => "true"})

      assert Initiatives.get_initiative(ini.id).agent_access == true
      assert has_element?(view, "#agent-access-toggle[checked]")
    end

    test "a non-owner member never sees the checkbox or the trust state", %{ini: ini} do
      editor = user("editor")
      {:ok, _} = Initiatives.add_member(ini.id, editor.id, "editor")

      {:ok, view, _html} =
        Phoenix.ConnTest.build_conn() |> log_in(editor) |> live(~p"/initiatives/#{ini.id}")

      refute has_element?(view, "#agent-access-toggle")
      refute has_element?(view, "#agent-trust-state")
      refute has_element?(view, "#agent-trust-confirm")
    end

    # AI-KNOBS-PARKED (m03.04): knobs off the UI+API; revive with the surface.
    @tag :skip
    test "set_ai_knobs is refused while access is off (server backstop)", %{
      conn: conn,
      ini: ini
    } do
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      view
      |> element("#ai-knobs-form")
      |> render_change(%{"ai_knobs" => "smuggled"})

      assert Initiatives.get_initiative(ini.id).ai_knobs == nil
    end
  end

  describe "trust-confirm predicate state + ack on the ENABLE path (2.12.4 b)" do
    test "enabling over an existing member records the ack; solo enabling does not", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      bob = user("bob")
      {:ok, _} = Initiatives.add_member(ini.id, bob.id, "viewer")

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      # The client's decision inputs at render: not acked, access off, others exist.
      assert has_element?(view, "#agent-trust-state[data-acked='false']")
      assert has_element?(view, "#agent-trust-state[data-agent-access='false']")
      assert has_element?(view, "#agent-trust-state[data-other-members='true']")
      assert has_element?(view, "#agent-trust-confirm")

      # Proceed injects `trust_confirmed` — that marker IS the acceptance.
      render_change(view, "set_agent_access", %{
        "agent_access" => "true",
        "trust_confirmed" => "true"
      })

      # acked persists and the state flips, so the dialog can never trigger
      # again for this (admin, Initiative).
      assert Initiatives.agent_trust_acked?(owner.id, ini.id)
      assert has_element?(view, "#agent-trust-state[data-acked='true']")
      assert has_element?(view, "#agent-trust-state[data-agent-access='true']")
    end

    test "enabling with no other members records no ack (nothing was confirmed)", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      assert has_element?(view, "#agent-trust-state[data-other-members='false']")

      render_change(view, "set_agent_access", %{"agent_access" => "true"})

      assert Initiatives.get_initiative(ini.id).agent_access == true
      refute Initiatives.agent_trust_acked?(owner.id, ini.id)
      assert has_element?(view, "#agent-trust-state[data-acked='false']")
    end
  end

  describe "trust-confirm ack on the MEMBER add/promote path (2.12.4 a)" do
    test "the first member add on an agent-accessible Initiative records the ack", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      assert has_element?(view, "#agent-trust-state[data-acked='false']")
      assert has_element?(view, "#agent-trust-state[data-agent-access='true']")

      render_submit(view, "add_member", %{
        "member" => bob.username,
        "role" => "viewer",
        "trust_confirmed" => "true"
      })

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
      assert Initiatives.agent_trust_acked?(owner.id, ini.id)
      # Second occurrence for the same (admin, Initiative): the client reads
      # data-acked=true and never opens the confirm again.
      assert has_element?(view, "#agent-trust-state[data-acked='true']")
    end

    test "a gated add WITHOUT the confirm marker records no ack (proof-carrying)", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      # An ungated push that matches the trigger predicate but lacks the
      # Proceed marker (a bypassed/absent client dialog) must not burn the
      # one-time ack — else the confirm silently never shows.
      render_submit(view, "add_member", %{"member" => bob.username, "role" => "viewer"})

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
      refute Initiatives.agent_trust_acked?(owner.id, ini.id)
      assert has_element?(view, "#agent-trust-state[data-acked='false']")
    end

    test "a member add with access OFF is confirm-free and records nothing", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      bob = user("bob")
      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      render_submit(view, "add_member", %{"member" => bob.username, "role" => "viewer"})

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
      refute Initiatives.agent_trust_acked?(owner.id, ini.id)
      assert has_element?(view, "#agent-trust-state[data-acked='false']")
    end

    test "a promotion on an agent-accessible Initiative records the ack", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      bob = user("bob")
      {:ok, _} = Initiatives.add_member(ini.id, bob.id, "viewer")
      {:ok, _} = Initiatives.set_agent_access(ini, true)

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")
      assert has_element?(view, "#agent-trust-state[data-acked='false']")

      # Promoting bob (viewer -> editor) is trigger path (a); the committed
      # change records the ack.
      render_change(view, "update_member_role", %{
        "user_id" => to_string(bob.id),
        "role" => "editor",
        "trust_confirmed" => "true"
      })

      assert Initiatives.get_role(ini.id, bob.id) == "editor"
      assert Initiatives.agent_trust_acked?(owner.id, ini.id)
      assert has_element?(view, "#agent-trust-state[data-acked='true']")
    end
  end

  describe "trust-confirm on the RAIL collaborator-add path (2.16)" do
    test "the rail entry carries the confirm-required state until the admin acks", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      {:ok, beta} = Initiatives.create_initiative(owner, %{"name" => "Beta Initiative"})

      # List mode: the drag path exists here too, so the entry state AND the
      # dialog must both render (the client fail-safes to no-add without it).
      {:ok, view, _html} = live(conn, ~p"/initiatives")

      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='true']"
             )

      assert has_element?(
               view,
               "[data-rail-initiative-id='#{beta.id}'][data-trust-confirm='false']"
             )

      assert has_element?(view, "#agent-trust-confirm")

      # Acked → the state flips for good and the dialog has no caller left.
      :ok = Initiatives.record_agent_trust_ack(owner, ini)
      {:ok, view, _html} = live(conn, ~p"/initiatives")

      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='false']"
             )

      refute has_element?(view, "#agent-trust-confirm")
    end

    test "a rail add with the Proceed marker records the ack and flips the rail state", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='true']"
             )

      # Proceed injects `trust_confirmed` into the pushed params — the marker
      # IS the acceptance, exactly like the members-panel paths.
      render_hook(view, "add_collaborator_to", %{
        "user-id" => to_string(bob.id),
        "initiative-id" => to_string(ini.id),
        "trust_confirmed" => "true"
      })

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
      assert Initiatives.agent_trust_acked?(owner.id, ini.id)
      # The server's rail refresh flips the entry state in place, and the
      # settings pane's own state flips with it — no path re-asks.
      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='false']"
             )

      assert has_element?(view, "#agent-trust-state[data-acked='true']")
    end

    test "an acked admin's rail add needs no confirm and just adds", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      :ok = Initiatives.record_agent_trust_ack(owner, ini)
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      # data-trust-confirm=false means the client never opens the dialog — the
      # bare (marker-less) push is the whole flow.
      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='false']"
             )

      render_hook(view, "add_collaborator_to", %{
        "user-id" => to_string(bob.id),
        "initiative-id" => to_string(ini.id)
      })

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"

      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='false']"
             )
    end

    test "a bare rail add without the marker records no ack (proof-carrying)", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/initiatives/#{ini.id}")

      # An ungated push matching the trigger predicate (a bypassed/absent
      # client dialog) must not burn the one-time ack.
      render_hook(view, "add_collaborator_to", %{
        "user-id" => to_string(bob.id),
        "initiative-id" => to_string(ini.id)
      })

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
      refute Initiatives.agent_trust_acked?(owner.id, ini.id)
      # The confirm is still owed — the rail state stays armed.
      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='true']"
             )
    end
  end

  describe "trust-confirm on the /assigned collaborator-drop path (2.21)" do
    test "a gated drop on /assigned shows the dialog state, adds, and records the ack", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/assigned")

      # The rail entry is armed and the dialog is mounted for the drop to open.
      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='true']"
             )

      assert has_element?(view, "#agent-trust-confirm")

      render_hook(view, "add_collaborator_to", %{
        "user-id" => to_string(bob.id),
        "initiative-id" => to_string(ini.id),
        "trust_confirmed" => "true"
      })

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
      assert Initiatives.agent_trust_acked?(owner.id, ini.id)
      # The rail refresh flips the entry in place; no gated entry remains, so
      # the dialog unrenders.
      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='false']"
             )

      refute has_element?(view, "#agent-trust-confirm")
    end

    test "a bare /assigned drop adds but records no ack (proof-carrying)", %{
      conn: conn,
      owner: owner,
      ini: ini
    } do
      {:ok, _} = Initiatives.set_agent_access(ini, true)
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/assigned")

      render_hook(view, "add_collaborator_to", %{
        "user-id" => to_string(bob.id),
        "initiative-id" => to_string(ini.id)
      })

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
      refute Initiatives.agent_trust_acked?(owner.id, ini.id)

      assert has_element?(
               view,
               "[data-rail-initiative-id='#{ini.id}'][data-trust-confirm='true']"
             )
    end

    test "no gated entry: no dialog on /assigned, an ungated drop just adds", %{
      conn: conn,
      ini: ini
    } do
      # Agent access off — the predicate can't match anywhere.
      bob = user("bob")

      {:ok, view, _html} = live(conn, ~p"/assigned")

      refute has_element?(view, "#agent-trust-confirm")

      render_hook(view, "add_collaborator_to", %{
        "user-id" => to_string(bob.id),
        "initiative-id" => to_string(ini.id)
      })

      assert Initiatives.get_role(ini.id, bob.id) == "viewer"
    end

    test "malformed ids on /assigned no-op instead of crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/assigned")

      render_hook(view, "add_collaborator_to", %{
        "user-id" => "garbage",
        "initiative-id" => "also-garbage"
      })

      # Still alive and rendering.
      assert has_element?(view, "#assigned-page")
    end
  end
end
