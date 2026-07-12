defmodule DoitMcp.Elicitation do
  @moduledoc """
  Thin wiring between a tool and the Anubis session process for
  server-initiated `elicitation/create` requests (m03.03 fix 10).

  Anubis runs a tool's `execute/2` in a per-request Task, and its own
  `Anubis.Server.send_elicitation_request/3` targets `self()` — the session
  only when called from session callbacks, never from a tool. So this module
  sends the same `{:send_elicitation_request, params, schema, timeout}` info
  message straight to the session process and parks the calling tool task in
  `receive` until `DoitMcp.Server.handle_elicitation/3` forwards the client's
  answer back (or the window lapses; the session cancels the client-side
  request on its own matching timer).

  One waiter at a time — safe here: the stdio adapter is one session per OS
  process and Anubis serializes tool calls within a session.
  """

  @waiter DoitMcp.Elicitation.Waiter

  @doc """
  The registered name of the session process this adapter talks to.
  Overridable via the `:elicitation_session_name` app env for tests.
  """
  def session_name do
    Application.get_env(
      :doit_mcp,
      :elicitation_session_name,
      Anubis.Server.Registry.stdio_session_name(DoitMcp.Server)
    )
  end

  @doc """
  Whether the connected client advertised the `elicitation` capability in its
  initialize handshake. Anubis keeps `client_capabilities` in session state
  without exposing it to a tool's frame, so this reads the session process
  directly. `false` when no session is up or the handshake hasn't happened.
  """
  @spec client_supports_elicitation?() :: boolean()
  def client_supports_elicitation? do
    case Process.whereis(session_name()) do
      nil ->
        false

      pid ->
        try do
          capabilities = :sys.get_state(pid).client_capabilities || %{}
          Map.has_key?(capabilities, "elicitation")
        catch
          :exit, _ -> false
        end
    end
  end

  @doc """
  Send an `elicitation/create` to the client and block until it answers.

  Returns `{:ok, result}` with the sanitized MCP elicitation result
  (`%{"action" => "accept", "content" => %{...}}`, `%{"action" => "decline"}`,
  or `%{"action" => "cancel"}`), or `{:error, :timeout | :no_session |
  :already_waiting}`. A client-side error response is only logged by Anubis —
  it never reaches `handle_elicitation/3` — so it surfaces here as `:timeout`.
  """
  @spec request(String.t(), map(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def request(message, requested_schema, timeout) do
    case Process.whereis(session_name()) do
      nil -> {:error, :no_session}
      pid -> do_request(pid, message, requested_schema, timeout)
    end
  end

  @doc "Forward a client's elicitation answer to the parked waiter, if any."
  @spec deliver(map()) :: :ok
  def deliver(result) do
    case Process.whereis(@waiter) do
      nil -> :ok
      pid -> send(pid, {:elicitation_result, result})
    end

    :ok
  end

  defp do_request(session_pid, message, requested_schema, timeout) do
    case Process.whereis(@waiter) do
      nil ->
        Process.register(self(), @waiter)
        params = %{"message" => message, "requestedSchema" => requested_schema}
        send(session_pid, {:send_elicitation_request, params, requested_schema, timeout})
        await(timeout)

      _pid ->
        {:error, :already_waiting}
    end
  end

  defp await(timeout) do
    receive do
      {:elicitation_result, result} -> {:ok, result}
    after
      # The session cancels the client-side request at `timeout`; the extra
      # second covers scheduling skew so its cancel wins that race.
      timeout + 1_000 -> {:error, :timeout}
    end
  after
    Process.unregister(@waiter)
  end
end
