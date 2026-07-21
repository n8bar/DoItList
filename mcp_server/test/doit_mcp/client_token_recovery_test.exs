defmodule DoitMcp.ClientTokenRecoveryTest do
  use ExUnit.Case, async: false

  alias DoitMcp.{Client, TokenRecovery}

  # Revoked-token recovery (m03.04 item 2.13), exercised through the one
  # request path every tool and resource shares. The elicitation transport
  # round trip itself is proven by DoitMcp.ElicitationFlowTest; here the
  # capability check and the form are injected seams
  # (:token_recovery_capable / :token_recovery_elicit app env), and the HTTP
  # side is a Req.Test stub counting real attempts.

  @moduletag :capture_log

  setup do
    TokenRecovery.reset()

    tmp = Path.join(System.tmp_dir!(), "token-recovery-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    persist_path = Path.join(tmp, "refresh.env")
    Application.put_env(:doit_mcp, :token_persist_path, persist_path)

    on_exit(fn ->
      TokenRecovery.reset()
      Application.delete_env(:doit_mcp, :token_persist_path)
      Application.delete_env(:doit_mcp, :token_recovery_capable)
      Application.delete_env(:doit_mcp, :token_recovery_elicit)
      File.rm_rf!(tmp)
    end)

    %{persist_path: persist_path}
  end

  defp capable, do: Application.put_env(:doit_mcp, :token_recovery_capable, fn -> true end)

  # Elicit seam that reports each invocation to the test process.
  defp elicit_returning(reply) do
    test_pid = self()

    Application.put_env(:doit_mcp, :token_recovery_elicit, fn message, schema, _timeout ->
      send(test_pid, {:elicited, message, schema})
      reply
    end)
  end

  # Stub answering 401 unless the bearer token matches `good`, counting calls.
  defp stub_401_unless(good) do
    counter = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(DoitMcp.Client, fn conn ->
      Agent.update(counter, &(&1 + 1))

      if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer #{good}"] do
        Req.Test.json(conn, %{"data" => %{"id" => 7}})
      else
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => %{"code" => "unauthorized", "message" => "invalid token"}})
      end
    end)

    counter
  end

  defp attempts(counter), do: Agent.get(counter, & &1)

  test "first 401 elicits, swaps in-process, retries once, and persists", %{
    persist_path: persist_path
  } do
    counter = stub_401_unless("fresh-token")
    capable()
    elicit_returning({:ok, %{"action" => "accept", "content" => %{"token" => "fresh-token"}}})

    assert {:ok, %{"id" => 7}} = Client.get("/api/v1/me")

    # The form asked for a token and explained the deal.
    assert_received {:elicited, message, schema}
    assert message =~ "rejected this session's API token"
    assert schema["required"] == ["token"]

    # Exactly one retry; the swap took for the rest of the session.
    assert attempts(counter) == 2
    assert TokenRecovery.token() == "fresh-token"

    # Persisted in the launcher-sourceable shape, locked down.
    assert File.read!(persist_path) =~ "DOITLIST_API_TOKEN=fresh-token"
    assert File.stat!(persist_path).mode |> Bitwise.band(0o777) == 0o600

    # Later calls use the refreshed token with no further elicitation.
    assert {:ok, %{"id" => 7}} = Client.get("/api/v1/me")
    refute_received {:elicited, _, _}
    assert attempts(counter) == 3
  end

  test "a declined form returns the actionable error and never re-elicits", %{
    persist_path: persist_path
  } do
    counter = stub_401_unless("never-granted")
    capable()
    elicit_returning({:ok, %{"action" => "decline"}})

    assert {:error, %{status: 401, body: %{"error" => %{"message" => message}}}} =
             Client.get("/api/v1/me")

    assert message =~ "declined"
    assert message =~ "mcp.env"
    assert message =~ "DOITLIST_API_TOKEN=<fresh token>"
    assert_received {:elicited, _, _}
    assert attempts(counter) == 1
    refute File.exists?(persist_path)

    # The latch holds: the next 401 goes straight to the error, no form.
    assert {:error, %{status: 401, body: %{"error" => %{"message" => message2}}}} =
             Client.get("/api/v1/me")

    assert message2 =~ "not asking again"
    refute_received {:elicited, _, _}
    assert attempts(counter) == 2
  end

  test "a bad pasted token retries once, then latches instead of looping" do
    counter = stub_401_unless("never-granted")
    capable()
    elicit_returning({:ok, %{"action" => "accept", "content" => %{"token" => "still-dead"}}})

    assert {:error, %{status: 401, body: %{"error" => %{"message" => message}}}} =
             Client.get("/api/v1/me")

    assert message =~ "rejected too"
    assert message =~ "mcp.env"
    assert_received {:elicited, _, _}
    # Original attempt + exactly one retry with the pasted token.
    assert attempts(counter) == 2

    # Second consecutive 401 territory: no new form, straight to the error.
    assert {:error, %{status: 401, body: %{"error" => %{"message" => message2}}}} =
             Client.get("/api/v1/me")

    assert message2 =~ "not asking again"
    refute_received {:elicited, _, _}
    assert attempts(counter) == 3
  end

  test "a paste with shell metacharacters is refused and never persisted", %{
    persist_path: persist_path
  } do
    counter = stub_401_unless("never-granted")
    capable()
    elicit_returning({:ok, %{"action" => "accept", "content" => %{"token" => "x; rm -rf /"}}})

    assert {:error, %{status: 401, body: %{"error" => %{"message" => message}}}} =
             Client.get("/api/v1/me")

    assert message =~ "wasn't usable"
    assert attempts(counter) == 1
    refute File.exists?(persist_path)
  end

  test "a non-elicitation client gets the token-file fix, not the bare 401" do
    counter = stub_401_unless("never-granted")
    Application.put_env(:doit_mcp, :token_recovery_capable, fn -> false end)

    Application.put_env(:doit_mcp, :token_recovery_elicit, fn _, _, _ ->
      raise "must not elicit without the capability"
    end)

    assert {:error, %{status: 401, body: %{"error" => %{"message" => message}}}} =
             Client.get("/api/v1/me")

    assert message =~ "mcp.env"
    assert message =~ "DOITLIST_API_TOKEN=<fresh token>"
    assert message =~ "reconnect"
    assert attempts(counter) == 1
  end

  test "the error names the real host path when the launcher passed it through" do
    stub_401_unless("never-granted")
    Application.put_env(:doit_mcp, :token_recovery_capable, fn -> false end)
    System.put_env("DOITLIST_MCP_ENV_PATH", "/home/op/.config/doitlist/mcp.env")
    on_exit(fn -> System.delete_env("DOITLIST_MCP_ENV_PATH") end)

    assert {:error, %{status: 401, body: %{"error" => %{"message" => message}}}} =
             Client.get("/api/v1/me")

    assert message =~ "/home/op/.config/doitlist/mcp.env"
  end

  test "with no injected seams the default capability check reports incapable (no session)" do
    counter = stub_401_unless("never-granted")

    assert {:error, %{status: 401, body: %{"error" => %{"message" => message}}}} =
             Client.get("/api/v1/me")

    assert message =~ "mcp.env"
    assert attempts(counter) == 1
  end

  test "a no-answer timeout does not latch — the next 401 may ask again" do
    counter = stub_401_unless("late-token")
    capable()
    elicit_returning({:error, :timeout})

    assert {:error, %{status: 401, body: %{"error" => %{"message" => message}}}} =
             Client.get("/api/v1/me")

    assert message =~ "no answer"
    assert_received {:elicited, _, _}
    assert attempts(counter) == 1

    # Operator is back now: the very next call elicits and succeeds.
    elicit_returning({:ok, %{"action" => "accept", "content" => %{"token" => "late-token"}}})
    assert {:ok, %{"id" => 7}} = Client.get("/api/v1/me")
    assert_received {:elicited, _, _}
    assert attempts(counter) == 3
  end
end
