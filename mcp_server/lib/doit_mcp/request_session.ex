defmodule DoitMcp.RequestSession do
  @moduledoc """
  The Anubis session behind the request THIS process serves (m03.04 item
  23.3), installed by `DoitMcp.Server.handle_request/2` alongside the
  session token.

  Anubis runs every request in its own task under the session's
  `Task.Supervisor`, so the session process is the head of the task's
  `$callers` chain, and the frame's context carries the session id. Modules
  that must reach the session — `DoitMcp.Elicitation` (park a waiter, read
  client capabilities, find the session's stream) and the 401 recovery's
  per-session state — read both from here rather than from any VM-wide
  registered name, which is what keeps them correct across concurrent
  sessions.

  Nothing installed (a unit test driving a tool directly) reads as `nil`;
  callers fall back to their registered-name resolution.
  """

  @key :doit_mcp_request_session

  @doc "Install this request task's session pid and session id."
  @spec install(Anubis.Server.Frame.t()) :: :ok
  def install(frame) do
    Process.put(@key, %{pid: callers_head(), id: session_id(frame)})
    :ok
  end

  @doc """
  Adopt another request's session identity — for a detached waiter acting on
  that request's behalf after its task returned (m03.04 item 27.1), so
  session-keyed state (Counter, pending confirms) reads the same rows the
  request did. Both values come from the originating task's `pid/0`/`id/0`,
  nil included.
  """
  @spec adopt(pid() | nil, String.t() | nil) :: :ok
  def adopt(pid, id) do
    Process.put(@key, %{pid: pid, id: id})
    :ok
  end

  @doc "The session process serving this request, or nil outside a request task."
  @spec pid() :: pid() | nil
  def pid do
    case Process.get(@key) do
      %{pid: pid} -> pid
      _ -> nil
    end
  end

  @doc "The session id this request arrived under, or nil outside a request task."
  @spec id() :: String.t() | nil
  def id do
    case Process.get(@key) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp callers_head do
    case Process.get(:"$callers") do
      [session | _] when is_pid(session) -> session
      _ -> nil
    end
  end

  defp session_id(%{context: %{session_id: id}}) when is_binary(id), do: id
  defp session_id(_frame), do: nil
end
