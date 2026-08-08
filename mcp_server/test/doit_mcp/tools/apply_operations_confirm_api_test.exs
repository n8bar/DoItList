defmodule DoitMcp.ApplyOperationsConfirmApiTest.FakeSession do
  @moduledoc """
  Stands in for the Anubis session process: holds `client_capabilities`
  where `DoitMcp.Elicitation` reads them and forwards elicitation sends to
  the test process.
  """
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: opts[:name])

  @impl true
  def init(opts) do
    {:ok, %{client_capabilities: opts[:capabilities], forward_to: opts[:forward_to]}}
  end

  @impl true
  def handle_info({:send_elicitation_request, _params, _schema, _timeout} = msg, state) do
    send(state.forward_to, msg)
    {:noreply, state}
  end
end

defmodule DoitMcp.ApplyOperationsConfirmApiTest do
  use ExUnit.Case, async: false

  alias Anubis.Server.Response
  alias DoitMcp.ApplyOperationsConfirmApiTest.FakeSession
  alias DoitMcp.ImportGate
  alias DoitMcp.Tools.ApplyOperations

  @moduledoc """
  The server-recorded confirm channel (m03.04 item 30): a gated hold PARKS
  the readback behind the API and hands back the confirm URL; a re-call
  CONSULTS the decision by payload hash — approved applies and settles,
  corrected returns the operator's text, held latches once then re-asks; a
  changed batch is a different hash, so it parks fresh. No client
  capability is load-bearing: a form-blind client rides the URL alone, and
  an unreachable confirm API fails LOUD, never a silent pass.
  """

  @threshold ImportGate.threshold()
  @frame %{test: true}
  @confirm_url "http://localhost:4000/initiatives/7#import-confirm"

  setup do
    Application.put_env(:doit_mcp, :import_gate_enabled, true)
    on_exit(fn -> Application.delete_env(:doit_mcp, :import_gate_enabled) end)
    :ok
  end

  defp start_gate_state do
    counter = :"#{__MODULE__}.Counter"
    pending = :"#{__MODULE__}.PendingConfirm"
    start_supervised!({DoitMcp.ImportGate.Counter, name: counter})
    start_supervised!({DoitMcp.ImportGate.PendingConfirm, name: pending})

    previous_counter = Application.fetch_env(:doit_mcp, :import_gate_counter)
    previous_pending = Application.fetch_env(:doit_mcp, :import_gate_pending_confirm)
    Application.put_env(:doit_mcp, :import_gate_counter, counter)
    Application.put_env(:doit_mcp, :import_gate_pending_confirm, pending)

    on_exit(fn ->
      case previous_counter do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_counter, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_counter)
      end

      case previous_pending do
        {:ok, value} -> Application.put_env(:doit_mcp, :import_gate_pending_confirm, value)
        :error -> Application.delete_env(:doit_mcp, :import_gate_pending_confirm)
      end
    end)
  end

  defp fake_session(capabilities) do
    name = :"#{__MODULE__}.FakeSession"
    start_supervised!({FakeSession, name: name, capabilities: capabilities, forward_to: self()})

    previous = Application.fetch_env(:doit_mcp, :elicitation_session_name)
    Application.put_env(:doit_mcp, :elicitation_session_name, name)
    Application.put_env(:doit_mcp, :elicitation_reachable, true)

    on_exit(fn ->
      Application.delete_env(:doit_mcp, :elicitation_reachable)

      case previous do
        {:ok, value} -> Application.put_env(:doit_mcp, :elicitation_session_name, value)
        :error -> Application.delete_env(:doit_mcp, :elicitation_session_name)
      end
    end)
  end

  defp elicitation_capable, do: fake_session(%{"elicitation" => %{}})

  defp existing_initiative_batch(task_count, initiative_id) do
    for i <- 1..task_count do
      %{
        "op" => "add",
        "type" => "task",
        "lid" => "t#{i}",
        "data" => %{"initiative_id" => initiative_id, "title" => "task #{i}"}
      }
    end
  end

  defp new_initiative_batch(task_count) do
    [%{"op" => "add", "type" => "initiative", "lid" => "i", "data" => %{"name" => "Import"}}] ++
      for i <- 1..task_count do
        %{
          "op" => "add",
          "type" => "task",
          "lid" => "t#{i}",
          "data" => %{"initiative_lid" => "i", "title" => "task #{i}"}
        }
      end
  end

  # The sha256 the adapter must compute — the pinned recipe, applied to the
  # atomized params the tool actually sees.
  defp expected_hash(operations) do
    :crypto.hash(:sha256, :erlang.term_to_binary(operations, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  # One stub serving the whole surface: task_count pressure, the confirm
  # consult (`consult` — :none → 404, a map → the row), the confirm park
  # (reported as {:parked, body}), and the ops apply (reported as :applied).
  defp stub_confirm_api(consult, opts \\ []) do
    reply_to = self()
    pressure = Keyword.get(opts, :pressure, 0)

    Req.Test.stub(DoitMcp.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/api/v1/import_confirms/" <> hash} ->
          case consult do
            :none ->
              conn
              |> Plug.Conn.put_status(404)
              |> Req.Test.json(%{"error" => %{"status" => 404, "code" => "not_found"}})

            :down ->
              conn
              |> Plug.Conn.put_status(500)
              |> Req.Test.json(%{"error" => %{"status" => 500, "code" => "internal"}})

            row when is_map(row) ->
              defaults = %{
                "payload_hash" => hash,
                "status" => "pending",
                "corrections" => nil,
                "url" => @confirm_url
              }

              Req.Test.json(conn, %{"data" => Map.merge(defaults, row)})
          end

        {"POST", "/api/v1/import_confirms"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          parked = Jason.decode!(body)
          send(reply_to, {:parked, parked})

          if Keyword.get(opts, :park, :ok) == :down do
            conn
            |> Plug.Conn.put_status(500)
            |> Req.Test.json(%{"error" => %{"status" => 500, "code" => "internal"}})
          else
            Req.Test.json(conn, %{
              "data" => %{
                "payload_hash" => parked["payload_hash"],
                "status" => "pending",
                "corrections" => nil,
                "url" => @confirm_url
              }
            })
          end

        {"GET", path} ->
          if String.ends_with?(path, "/task_count") do
            Req.Test.json(conn, %{"data" => %{"count" => pressure}})
          else
            # The post-apply repo-marker read: no summaries, no suggestion.
            Req.Test.json(conn, %{"data" => []})
          end

        {"POST", "/api/v1/operations"} ->
          send(reply_to, :applied)
          Req.Test.json(conn, %{"results" => []})
      end
    end)
  end

  defp decode_json_content(response) do
    protocol = Response.to_protocol(response)
    assert [%{"type" => "text", "text" => text} | rest] = protocol["content"]
    {protocol, Jason.decode!(text), rest}
  end

  defp execute(params), do: ApplyOperations.execute(params, @frame)

  test "a gated hold parks the confirm — hash, verbatim readback, Initiative home — and returns its URL" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:none)

    ops = existing_initiative_batch(@threshold + 1, 7)

    assert {:reply, response, @frame} =
             execute(%{operations: ops, readback: "Importing 31 tasks."})

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["status"] == "confirmation_pending"
    assert decoded["applied"] == false
    assert decoded["confirm_url"] == @confirm_url
    assert decoded["message"] =~ "confirm_url"
    refute decoded["message"] =~ "operator_decision"

    assert_received {:parked, parked}
    assert parked["payload_hash"] == expected_hash(ops)
    assert parked["initiative_id"] == 7
    # The parked readback is the COMPOSED message, verbatim — what the card
    # shows is exactly what the tool returned.
    assert parked["readback"] == decoded["readback"]
    refute_received :applied
  end

  test "a bootstrap batch parks with no initiative_id — homed on the account" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:none)

    ops = new_initiative_batch(@threshold + 1)
    assert {:reply, _response, @frame} = execute(%{operations: ops, readback: "Importing."})

    assert_received {:parked, parked}
    refute Map.has_key?(parked, "initiative_id")
  end

  test "an in-app approval applies the plain re-call and settles the session" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:none)

    ops = existing_initiative_batch(@threshold + 1, 7)
    assert {:reply, _, @frame} = execute(%{operations: ops, readback: "Importing 31 tasks."})
    assert_received {:parked, _}

    # The operator approved in the app; the server knows. The PLAIN re-call
    # (no readback, no form answer) consults, applies, and notes the confirm.
    stub_confirm_api(%{"status" => "approved"})
    assert {:reply, response, @frame} = execute(%{operations: ops})

    {protocol, decoded, rest} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["ok"] == true
    assert [%{"type" => "text", "text" => note}] = rest
    assert note =~ "confirmed"
    assert_received :applied

    # Settled: a later over-the-line chunk flows without consulting anything
    # — the 404 consult stub would park it if the session hadn't settled.
    stub_confirm_api(:none, pressure: 200)
    assert {:reply, response, @frame} = execute(%{operations: existing_initiative_batch(15, 7)})
    {_, decoded, _} = decode_json_content(response)
    assert decoded["ok"] == true
    refute_received {:parked, _}
  end

  test "corrected returns the operator's text on the re-call; nothing applies" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:none)

    ops = existing_initiative_batch(@threshold + 1, 7)
    assert {:reply, _, @frame} = execute(%{operations: ops, readback: "Importing 31 tasks."})

    stub_confirm_api(%{"status" => "corrected", "corrections" => "Milestones only"})
    assert {:reply, response, @frame} = execute(%{operations: ops})

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["corrections"] == "Milestones only"
    assert decoded["message"] =~ "Revise"
    refute_received :applied
  end

  test "held latches like a decline, once — the next re-call re-parks and is re-asked" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:none)

    ops = existing_initiative_batch(@threshold + 1, 7)
    assert {:reply, _, @frame} = execute(%{operations: ops, readback: "Importing 31 tasks."})
    assert_received {:parked, _}

    stub_confirm_api(%{"status" => "held"})
    assert {:reply, response, @frame} = execute(%{operations: ops})

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "hold"
    assert decoded["message"] =~ "questions"
    refute_received :applied

    # Consumed. The same batch re-called again re-parks a FRESH confirm —
    # the park POST opens a new pending row past the decided one — so the
    # operator is re-asked instead of the hold latching forever.
    assert {:reply, response, @frame} =
             execute(%{operations: ops, readback: "Importing 31 tasks."})

    {_, decoded, _} = decode_json_content(response)
    assert decoded["status"] == "confirmation_pending"
    assert_received {:parked, _}
  end

  test "a changed batch is a different hash — it parks fresh instead of riding the old confirm" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:none)

    ops = existing_initiative_batch(@threshold + 1, 7)
    assert {:reply, _, @frame} = execute(%{operations: ops, readback: "Importing 31 tasks."})
    assert_received {:parked, %{"payload_hash" => first_hash}}

    revised = existing_initiative_batch(@threshold + 2, 7)
    assert {:reply, _, @frame} = execute(%{operations: revised, readback: "Importing 32 tasks."})
    assert_received {:parked, %{"payload_hash" => second_hash}}

    assert first_hash == expected_hash(ops)
    assert second_hash == expected_hash(revised)
    refute first_hash == second_hash
  end

  test "a form-blind client parks URL-only — the gate holds, no elicitation rides" do
    start_gate_state()
    fake_session(%{"sampling" => %{}})
    stub_confirm_api(:none)

    ops = existing_initiative_batch(@threshold + 1, 7)

    assert {:reply, response, @frame} =
             execute(%{operations: ops, readback: "Importing 31 tasks."})

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == false
    assert decoded["status"] == "confirmation_pending"
    assert decoded["confirm_url"] == @confirm_url
    assert_received {:parked, _}
    refute_received {:send_elicitation_request, _, _, _}

    # And the app channel alone resolves it.
    stub_confirm_api(%{"status" => "approved"})
    assert {:reply, response, @frame} = execute(%{operations: ops})
    {_, decoded, _} = decode_json_content(response)
    assert decoded["ok"] == true
    assert_received :applied
  end

  test "a park failure is LOUD — batch not applied, the confirm channel named" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:none, park: :down)

    ops = existing_initiative_batch(@threshold + 1, 7)

    assert {:reply, response, @frame} =
             execute(%{operations: ops, readback: "Importing 31 tasks."})

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "confirm channel is unavailable"
    refute_received :applied
    refute_received {:send_elicitation_request, _, _, _}
  end

  test "a consult failure is LOUD — never a silent pass" do
    start_gate_state()
    elicitation_capable()
    stub_confirm_api(:down)

    ops = existing_initiative_batch(@threshold + 1, 7)

    assert {:reply, response, @frame} =
             execute(%{operations: ops, readback: "Importing 31 tasks."})

    {protocol, decoded, _} = decode_json_content(response)
    assert protocol["isError"] == true
    assert decoded["applied"] == false
    assert decoded["message"] =~ "confirm channel is unavailable"
    refute_received :applied
  end
end
