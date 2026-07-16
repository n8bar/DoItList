defmodule DoitMcp.SessionIdleTimeoutTest do
  use ExUnit.Case, async: true

  alias Anubis.Server.Session

  # Session logs its starting/expiry lifecycle; keep test output clean.
  @moduletag :capture_log

  # Anubis expires an idle session and stops its process — but on stdio the
  # pipe outlives the session, so the 30-minute default turned every
  # long-idle client into -32600 "Server not initialized" (m03.03 item
  # 4.3.1.8). These tests pin the expiry contract the fix relies on and
  # prove the value we wire is one a session actually accepts.

  defp start_session(idle_timeout, name) do
    start_supervised!(
      Supervisor.child_spec(
        {Session,
         session_id: "idle-test",
         server_module: DoitMcp.Server,
         name: name,
         transport: [layer: Anubis.Server.Transport.STDIO, name: :"#{name}.Transport"],
         task_supervisor: :"#{name}.TaskSup",
         session_idle_timeout: idle_timeout},
        # An expired session must not be restarted into expiring again.
        restart: :temporary
      )
    )
  end

  test "an idle session stops with :session_expired once session_idle_timeout elapses" do
    session = start_session(150, :"#{__MODULE__}.ExpiringSession")

    ref = Process.monitor(session)
    assert_receive {:DOWN, ^ref, :process, ^session, {:shutdown, :session_expired}}, 2_000
  end

  test "the wired stdio timeout is accepted by a session and lands in its state" do
    {DoitMcp.Stdio.Supervisor, opts} =
      Enum.find(DoitMcp.Application.children(:dev), &match?({DoitMcp.Stdio.Supervisor, _}, &1))

    timeout = Keyword.fetch!(opts, :session_idle_timeout)
    session = start_session(timeout, :"#{__MODULE__}.PinnedSession")

    assert :sys.get_state(session).session_idle_timeout == timeout
  end
end
