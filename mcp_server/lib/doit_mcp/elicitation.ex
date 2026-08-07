defmodule DoitMcp.Elicitation do
  @moduledoc """
  Thin wiring between a tool and the Anubis session process for
  server-initiated `elicitation/create` requests (m03.04 fix 10).

  Anubis runs a tool's `execute/2` in a per-request Task, and its own
  `Anubis.Server.send_elicitation_request/3` targets `self()` — the session
  only when called from session callbacks, never from a tool. So this module
  sends the same `{:send_elicitation_request, params, schema, timeout}` info
  message straight to the session process and parks the calling tool task in
  `receive` until `DoitMcp.Server.handle_elicitation/3` forwards the client's
  answer back (or the window lapses; the session cancels the client-side
  request on its own matching timer). `request_async/4` is the decoupled
  variant (m03.04 item 27.1): same send, but a detached waiter parks in the
  calling task's place, so a human-paced answer never rides inside a
  transport-bounded call.

  A request task reads its own session from `DoitMcp.RequestSession` (m03.04
  item 23.3); a caller outside a request task (unit tests driving a tool
  directly) falls back to the session registered under the
  `:elicitation_session_name` app env, which is how those tests point this
  module at their fake session.
  Waiters register in the `DoitMcp.Elicitation.Registry` KEYED BY SESSION
  process, so concurrent sessions elicit independently while each stays one
  waiter at a time (Anubis serializes requests within a session). The answer
  dispatches `handle_elicitation` IN the session process — that identity is
  how `deliver/1` finds the right waiter.
  """

  require Logger

  alias DoitMcp.RequestSession

  @registry DoitMcp.Elicitation.Registry

  @doc """
  Whether the connected client advertised the `elicitation` capability in its
  initialize handshake. Anubis keeps `client_capabilities` in session state
  without exposing it to a tool's frame, so this reads the session process
  directly. `false` when no session is up or the handshake hasn't happened.
  """
  @spec client_supports_elicitation?() :: boolean()
  def client_supports_elicitation? do
    case current_session() do
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
  Whether a server-initiated request can reach the client RIGHT NOW: it
  requires the session's standalone GET stream, since the transport routes an
  elicitation to that session's own stream and a missing handler is a silent
  drop (the session logs the failed send and forgets it). Callers check here
  first — a parked waiter would otherwise hang to its timeout (m03.04 item
  23.3).

  Overridable via the `:elicitation_reachable` app env: a test that stands in
  for the transport itself answers for its own channel, the way
  `:elicitation_session_name` stands in for the session.
  """
  @spec reachable?() :: boolean()
  def reachable? do
    case Application.fetch_env(:doit_mcp, :elicitation_reachable) do
      {:ok, reachable?} -> reachable?
      :error -> stream_open?()
    end
  end

  defp stream_open? do
    transport = Anubis.Server.Registry.transport_name(DoitMcp.Server, :streamable_http)
    session_id = RequestSession.id()

    is_binary(session_id) and
      Anubis.Server.Transport.StreamableHTTP.get_sse_handler(transport, session_id) != nil
  catch
    :exit, _ -> false
  end

  @doc """
  Send an `elicitation/create` to the client and block until it answers.

  Returns `{:ok, result}` with the sanitized MCP elicitation result
  (`%{"action" => "accept", "content" => %{...}}`, `%{"action" => "decline"}`,
  or `%{"action" => "cancel"}`), or `{:error, :timeout | :no_session |
  :no_sse_handler | :already_waiting}` — `:no_sse_handler` when an HTTP
  session holds no standalone GET stream to carry the request. A client-side
  error response is only logged by Anubis — it never reaches
  `handle_elicitation/3` — so it surfaces here as `:timeout`.
  """
  @spec request(String.t(), map(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def request(message, requested_schema, timeout) do
    case current_session() do
      nil ->
        {:error, :no_session}

      pid ->
        if reachable?() do
          do_request(pid, message, requested_schema, timeout)
        else
          {:error, :no_sse_handler}
        end
    end
  end

  @doc """
  Send an `elicitation/create` and return immediately, leaving a DETACHED
  waiter parked for the answer (m03.04 item 27.1): a human-paced confirm
  must never ride inside a transport-bounded call. The waiter claims this
  session's registry slot exactly like `request/3`'s inline wait, adopts the
  calling request's session identity so `on_answer` (run in the waiter when
  the client answers) reads the same session-keyed state the request did,
  and dies on the first of: the answer, the session's death, or `timeout` —
  an abandoned form never leaks a waiter (the session cancels the
  client-side form on its own matching timer). Returns `:ok`, or the same
  errors as `request/3` — `:already_waiting` means a form is already out on
  this session, so callers proceed without a second send.
  """
  @spec request_async(String.t(), map(), non_neg_integer(), (map() -> any())) ::
          :ok | {:error, atom()}
  def request_async(message, requested_schema, timeout, on_answer) do
    case current_session() do
      nil ->
        {:error, :no_session}

      session ->
        if reachable?() do
          identity = {RequestSession.pid(), RequestSession.id()}
          start_waiter(session, identity, message, requested_schema, timeout, on_answer)
        else
          {:error, :no_sse_handler}
        end
    end
  end

  # The waiter registers ITSELF (the registry cleans the slot on its death)
  # and acks the caller before parking, so request_async/4 returns knowing
  # the slot was won or lost. Unsupervised by design: its lifetime is
  # bounded by the expiry timer and the session monitor.
  defp start_waiter(session, {identity_pid, identity_id}, message, schema, timeout, on_answer) do
    caller = self()
    ack = make_ref()

    waiter =
      spawn(fn ->
        case Registry.register(@registry, session, :async) do
          {:ok, _owner} ->
            send(caller, {ack, :ok})
            RequestSession.adopt(identity_pid, identity_id)
            session_ref = Process.monitor(session)
            params = %{"message" => message, "requestedSchema" => schema}
            send(session, {:send_elicitation_request, params, schema, timeout})

            try do
              receive do
                {:elicitation_result, result} ->
                  on_answer.(result)

                {:DOWN, ^session_ref, :process, _pid, _reason} ->
                  :ok
              after
                # The session cancels the client-side form at `timeout`; the
                # extra second covers scheduling skew so its cancel wins.
                timeout + 1_000 ->
                  Logger.info("elicitation waiter expired unanswered after #{timeout}ms")
              end
            after
              # Explicit, like do_request/4's — a dead owner's entry lapses
              # asynchronously, and the next form must be able to claim the
              # slot the moment this waiter's death is observed.
              Registry.unregister(@registry, session)
            end

          {:error, {:already_registered, _pid}} ->
            send(caller, {ack, :already_waiting})
        end
      end)

    monitor = Process.monitor(waiter)

    receive do
      {^ack, :ok} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {^ack, :already_waiting} ->
        Process.demonitor(monitor, [:flush])
        {:error, :already_waiting}

      {:DOWN, ^monitor, :process, _pid, _reason} ->
        {:error, :waiter_died}
    end
  end

  @doc "Forward a client's elicitation answer to the parked waiter, if any."
  @spec deliver(map()) :: :ok
  def deliver(result) do
    # Anubis dispatches handle_elicitation IN the session process, so self()
    # keys the waiter; the named fallback serves callers outside any session
    # (tests driving deliver directly against a fake session).
    delivered = notify(self(), result) || notify(configured_session(), result)

    unless delivered do
      Logger.info("elicitation answer arrived with no waiter (expired or resolved) — ignored")
    end

    :ok
  end

  defp notify(nil, _result), do: false

  defp notify(session, result) do
    case Registry.lookup(@registry, session) do
      [{waiter, _value}] ->
        send(waiter, {:elicitation_result, result})
        true

      [] ->
        false
    end
  end

  defp current_session do
    RequestSession.pid() || configured_session()
  end

  # The fallback for callers outside a request task: the session registered
  # under :elicitation_session_name, or nil when nothing configured one.
  defp configured_session do
    case Application.get_env(:doit_mcp, :elicitation_session_name) do
      nil -> nil
      name -> Process.whereis(name)
    end
  end

  defp do_request(session_pid, message, requested_schema, timeout) do
    # Registry.register is register-and-check in ONE atomic step per session
    # key: the loser of two concurrent requests on the same session gets
    # :already_waiting instead of a race, and a dead waiter's entry cleans
    # itself up (the registry monitors owners).
    case Registry.register(@registry, session_pid, nil) do
      {:ok, _owner} ->
        try do
          params = %{"message" => message, "requestedSchema" => requested_schema}
          send(session_pid, {:send_elicitation_request, params, requested_schema, timeout})
          await(timeout)
        after
          Registry.unregister(@registry, session_pid)
        end

      {:error, {:already_registered, _pid}} ->
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
  end
end
